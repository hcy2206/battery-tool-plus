# Battery Tool Plus v1.0.0

首个正式版。应用行为与 0.4.3 相同：自动充放电循环、CPU / GPU 负载、定时任务与截止目标、空闲时段推荐、实时功率与历史记录、PushDeer 推送、合盖放电与睡眠加固。本版本整理了文档与仓库结构。

## 变更

- **README 改为产品介绍**，附控制台截图；操作细节移到 `docs/USER_GUIDE.md`。
- **文档集中到 `docs/`**：使用指南、开发指南、发布指南、变更记录、第三方声明。`macos/README.md` 并入使用指南。
- **精简工具链**：CI 直接调用 ruff / basedpyright / pytest / meson，移除 nox 与 Brewfile。

完整历史见 [CHANGELOG](https://github.com/hcy2206/battery-tool-plus/blob/main/docs/CHANGELOG.md)。

## 下载与安装

下载 `BatteryToolPlus-1.0.0-macos-arm64.dmg`，双击挂载后把 `Battery Tool Plus.app` 拖到旁边的 Applications 快捷方式上。
支持 Apple Silicon、macOS 15 及以上，无需 Python。

应用使用 ad-hoc 签名。首次打开时在"系统设置 → 隐私与安全性"点"仍要打开"，
或执行 `xattr -dr com.apple.quarantine "/Applications/Battery Tool Plus.app"`。
图形应用以普通用户运行，电池控制在应用内按需请求管理员授权。
