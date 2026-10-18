# Battery Tool Plus v0.4.0-beta.1

Battery Tool Plus 的首个 macOS 图形管理版本，基于 BatteryTool 0.3.0。

## 新增功能

- SwiftUI 管理窗口与菜单栏入口：实时电量、健康度、循环次数、电源状态和本地电量历史。
- 三种模式：准备外出、日常循环、定时压测；定时任务区分“到点开始使用电脑”和“到点携带电脑离开”。
- CPU / Metal GPU 负载覆盖充电和放电全程，使用电脑时自动暂停，跟随系统温控降载。
- 初始空闲时段、基于本地记录的空闲推荐、无负载充电速度估算。
- 图形应用与 CLI 互斥控制；CLI 输入校验、SMC 错误处理与退出恢复修复。

## 下载与安装

下载 `BatteryToolPlus-0.4.0-beta.1-macos-arm64.dmg`，双击挂载后把 `BatteryTool.app` 拖到 Applications。
支持 Apple Silicon、macOS 15 及以上，无需 Python。

应用使用 ad-hoc 签名。首次打开时在“系统设置 → 隐私与安全性”点“仍要打开”。
图形应用以普通用户运行，电池控制在应用内按需请求管理员授权。
校验方法和重新签名命令见 README。本项目不发布 PyPI 包。

## 测试范围

- 自动化覆盖：Python 回归、原生策略/历史、演示控制器与 IPC 集成测试、四页界面渲染、应用构建与签名校验。
- macOS 27（M2 Max，固件 20457.1.29）实机确认：电池读数正确，`CHIE` 可用，循环充放电只靠切断/恢复适配器完成；该固件没有可用的充电抑制键。
- macOS 15.0–26.6 的 `CH0B/CH0C` 与 `CHTE` 路径沿用上游实现，由模拟后端回归测试覆盖；长时间压测请在插电状态下先用短窗口试运行。
- 充电完成时间和空闲窗口为估算值；高负载会增加耗电与发热。历史记录只保存在本机，默认关闭。

## 许可证与源码

组合应用按 GPL-3.0-only 分发，保留上游 Apache-2.0 与 SMC 的原始许可声明。
`BatteryToolPlus-0.4.0-beta.1-source.tar.gz` 是与二进制同一提交的完整源码；校验值见 `SHA256SUMS`。

反馈：https://github.com/hcy2206/battery-tool-plus/issues
