# 相册文件视频进度条 (IVGlassPlayer)

给「照片」和「文件」App 的全屏视频播放加一层玻璃风格控件：

- 底部胶囊进度条，长按展开为可拖动时间轴
- 中央玻璃按钮组：后退 15 秒 / 播放暂停 / 前进 15 秒
- 播放结束后点播放从头重播

Rootless（`/var/jb`），支持 iOS 14+，仅依赖 `mobilesubstrate`。

## 构建

```bash
make package FINALPACKAGE=1          # 出 iphoneos-arm64（fat arm64 + arm64e）
python3 tools/make-arm64e-deb.py packages   # 再派生一个 iphoneos-arm64e 专用包
```

CI（`.github/workflows/build.yml`）在每次 push 到 `main` 时自动产出两个 deb。

## 进程注入

| App | 进程 |
|---|---|
| 照片 | `com.apple.mobileslideshow` |
| 文件 | `com.apple.quicklook.extension.previewUI`（QuickLook 预览扩展） |

见 `IVGlassPlayer.plist` 与 `Tweak.xm` 里的 `IVIsTargetProcess()`。
