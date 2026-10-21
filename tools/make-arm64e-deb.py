#!/usr/bin/env python3
"""从 rootless 的 fat deb 派生一个 arm64e 专用 deb。

用法：
    python3 tools/make-arm64e-deb.py packages
    python3 tools/make-arm64e-deb.py path/to/xxx.deb

做的事：
  1. 读原 deb，取出 dylib / filter plist / control
  2. lipo -thin arm64e 取 arm64e 切片，并用 ldid -S 重新签名
  3. 改写 control：Package 加 .arm64e 后缀、Architecture 改 iphoneos-arm64e，
     加 Conflicts + Replaces 指向原包，避免两个包同时装打架
  4. 重新打成 deb（debian-binary + control.tar.gz + data.tar.gz）

只依赖 Python 标准库 + lipo / ldid。
"""
import glob
import gzip
import io
import lzma
import os
import shutil
import subprocess
import sys
import tarfile
import time

DYLD_DIR = "var/jb/Library/MobileSubstrate/DynamicLibraries"
DYLIB = "IVGlassPlayer.dylib"
FILTER = "IVGlassPlayer.plist"


# ---------------------------------------------------------------- ar / tar

def parse_ar(data: bytes):
    """解析 ar 容器，返回 [(name, payload)]，顺序保留。"""
    if not data.startswith(b"!<arch>\n"):
        raise SystemExit("不是 ar 容器，可能不是 deb")
    out = []
    off = 8
    n = len(data)
    while off + 60 <= n:
        hdr = data[off:off + 60]
        if hdr[58:60] != b"`\n":
            raise SystemExit("ar 头损坏 @%d" % off)
        name = hdr[0:16].decode("utf-8", "replace").strip()
        size = int(hdr[48:58].decode().strip())
        body = data[off + 60:off + 60 + size]
        # BSD ar 会把真实名字塞在 body 开头，形如 #1/16
        if name.startswith("#1/"):
            ln = int(name[3:])
            name = body[:ln].decode("utf-8", "replace").rstrip("\0")
            body = body[ln:]
        out.append((name.rstrip("/"), body))
        off += 60 + size + (size % 2)
    return out


def decompress_tar(name: str, payload: bytes) -> bytes:
    """把 control.tar.* / data.tar.* 解成裸 tar 字节。"""
    if name.endswith(".gz"):
        return gzip.decompress(payload)
    if name.endswith(".xz"):
        return lzma.decompress(payload)          # 自动识别 xz
    if name.endswith(".lzma"):
        return lzma.decompress(payload, format=lzma.FORMAT_ALONE)
    if name.endswith(".zst"):
        raise SystemExit("不支持 zstd，请换个压缩方式重新打包")
    return payload                                # .tar


def tar_members(raw: bytes):
    """返回 {路径: (TarInfo, bytes)}，只收普通文件。"""
    out = {}
    with tarfile.open(fileobj=io.BytesIO(raw), mode="r:") as tar:
        for ti in tar.getmembers():
            if not ti.isreg():
                continue
            f = tar.extractfile(ti)
            out[ti.name.lstrip("./")] = (ti, f.read() if f else b"")
    return out


def tar_gz(entries, mtime: int) -> bytes:
    """entries: [(path, kind, payload, mode)]，kind 为 'dir' 或 'file'。"""
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.GNU_FORMAT) as tar:
        for path, kind, payload, mode in entries:
            ti = tarfile.TarInfo(path)
            ti.mode = mode
            ti.mtime = mtime
            ti.uid = 0
            ti.gid = 0
            ti.uname = "root"
            ti.gname = "wheel"
            if kind == "dir":
                ti.type = tarfile.DIRTYPE
                ti.size = 0
                tar.addfile(ti)
            else:
                ti.type = tarfile.REGTYPE
                ti.size = len(payload)
                tar.addfile(ti, io.BytesIO(payload))
    return gzip.compress(buf.getvalue(), 9, mtime=mtime)


def build_ar(members, mtime: int) -> bytes:
    """空格填充、不带尾部 '/' 的名字 —— 和 dpkg-deb 的写法一致。"""
    out = io.BytesIO()
    out.write(b"!<arch>\n")
    for name, payload in members:
        header = (
            name.ljust(16)[:16].encode()
            + str(int(mtime)).ljust(12)[:12].encode()
            + b"0".ljust(6)
            + b"0".ljust(6)
            + b"100644".ljust(8)[:8]
            + str(len(payload)).ljust(10)[:10].encode()
            + b"`\n"
        )
        assert len(header) == 60
        out.write(header)
        out.write(payload)
        if len(payload) % 2:
            out.write(b"\n")
    return out.getvalue()


# ---------------------------------------------------------------- control

def rewrite_control(text: str) -> str:
    lines = text.splitlines()
    keep, seen = [], {k: False for k in ("Package", "Architecture", "Name", "Installed-Size")}
    pkg = arch = None
    for ln in lines:
        if ":" not in ln:
            keep.append(ln)
            continue
        key = ln.split(":", 1)[0].strip()
        if key == "Package":
            pkg = ln.split(":", 1)[1].strip()
            keep.append("Package: %s.arm64e" % pkg)
            seen["Package"] = True
        elif key == "Architecture":
            keep.append("Architecture: iphoneos-arm64e")
            seen["Architecture"] = True
        elif key == "Name":
            keep.append("%s (arm64e)" % ln)
            seen["Name"] = True
        elif key == "Installed-Size":
            continue                       # 由调用方重算
        elif key in ("Conflicts", "Replaces", "Provides"):
            continue                       # 由下面统一重建
        else:
            keep.append(ln)

    if not seen["Architecture"]:
        keep.append("Architecture: iphoneos-arm64e")
    if not seen["Package"]:
        raise SystemExit("control 里没有 Package 字段")
    if not seen["Name"]:
        keep.append("Name: %s (arm64e)" % (pkg or "tweak"))

    keep.append("Conflicts: %s" % pkg)
    keep.append("Replaces: %s" % pkg)
    return "\n".join(keep).rstrip("\n") + "\n"


def main():
    target = sys.argv[1] if len(sys.argv) > 1 else "packages"
    if os.path.isdir(target):
        cands = [p for p in glob.glob(os.path.join(target, "*.deb"))
                 if ".arm64e_" not in os.path.basename(p)]
        if not cands:
            raise SystemExit("%s 下没有 deb" % target)
        src = max(cands, key=os.path.getmtime)
    else:
        src = target

    print("源包: %s" % src)
    raw = open(src, "rb").read()
    members = parse_ar(raw)

    ctl_name, ctl_payload = next(((n, b) for n, b in members if n.startswith("control.tar")), (None, None))
    data_name, data_payload = next(((n, b) for n, b in members if n.startswith("data.tar")), (None, None))
    if not ctl_name or not data_name:
        raise SystemExit("deb 结构异常：缺 control.tar 或 data.tar")

    ctl = tar_members(decompress_tar(ctl_name, ctl_payload))
    data = tar_members(decompress_tar(data_name, data_payload))

    ctl_key = next(k for k in ctl if k.endswith("control"))
    control = ctl[ctl_key][1].decode("utf-8")

    dylib_key = next((k for k in data if k.endswith(DYLIB)), None)
    filter_key = next((k for k in data if k.endswith(FILTER)), None)
    if not dylib_key or not filter_key:
        raise SystemExit("data.tar 里找不到 %s / %s" % (DYLIB, FILTER))

    # ---- thin + 重签 ----
    tmp = os.path.join(os.path.dirname(os.path.abspath(src)), ".arm64e-tmp")
    os.makedirs(tmp, exist_ok=True)
    fat = os.path.join(tmp, "fat.dylib")
    thin = os.path.join(tmp, "thin.dylib")
    open(fat, "wb").write(data[dylib_key][1])

    subprocess.run(["lipo", "-thin", "arm64e", "-output", thin, fat], check=True)

    ldid = shutil.which("ldid") or os.path.expanduser("~/theos/bin/ldid")
    if os.path.exists(ldid):
        subprocess.run([ldid, "-S", thin], check=True)
        print("  ldid -S 重签完成")
    else:
        raise SystemExit("找不到 ldid；arm64e 切片必须签名")

    thin_bytes = open(thin, "rb").read()
    filter_bytes = data[filter_key][1]
    shutil.rmtree(tmp, ignore_errors=True)

    inst_size = max(1, (len(thin_bytes) + len(filter_bytes) + 1023) // 1024)
    control = rewrite_control(control).rstrip("\n") + "\nInstalled-Size: %d\n" % inst_size

    mtime = int(os.environ.get("SOURCE_DATE_EPOCH") or time.time())

    # ---- data.tar.gz ----
    parts = DYLD_DIR.split("/")
    entries = [("./", "dir", b"", 0o755)]
    acc = ""
    for p in parts:
        acc = acc + "/" + p if acc else p
        entries.append(("./" + acc, "dir", b"", 0o755))
    entries.append(("./" + DYLD_DIR + "/" + DYLIB, "file", thin_bytes, 0o755))
    entries.append(("./" + DYLD_DIR + "/" + FILTER, "file", filter_bytes, 0o644))

    deb = build_ar([
        ("debian-binary", b"2.0\n"),
        ("control.tar.gz", tar_gz([("./", "dir", b"", 0o755),
                                   ("./control", "file", control.encode(), 0o644)], mtime)),
        ("data.tar.gz", tar_gz(entries, mtime)),
    ], mtime)

    pkg = next(l.split(":", 1)[1].strip() for l in control.splitlines() if l.startswith("Package:"))
    ver = next(l.split(":", 1)[1].strip() for l in control.splitlines() if l.startswith("Version:"))
    out = os.path.join(os.path.dirname(src), "%s_%s_iphoneos-arm64e.deb" % (pkg, ver))
    open(out, "wb").write(deb)
    print("产出: %s (%d bytes)" % (out, len(deb)))


if __name__ == "__main__":
    main()
