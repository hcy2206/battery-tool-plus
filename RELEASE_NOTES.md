# Battery Tool Plus v0.4.0-beta.1

Battery Tool Plus 首个 macOS 图形管理测试版，基于 BatteryTool 0.3.0。

## 新增功能

- SwiftUI 管理窗口、菜单栏、状态与本地电量历史。
- 准备外出、日常循环、定时压测；截止目标区分继续桌面工作与携带离开。
- CPU / Metal GPU 负载覆盖充放电阶段，支持用户活动暂停与系统温控。
- 初始空闲窗口、基于历史的空闲推荐、充电预留时间估计。
- CLI 与图形应用互斥控制，修复输入校验、SMC 错误处理及退出恢复。

## 下载与安装

下载 `BatteryToolPlus-0.4.0-beta.1-macos-arm64.zip`，解压后将 `BatteryTool.app`
复制到“应用程序”。仅支持 Apple Silicon，构建目标 macOS 15+；无需 Python。
应用使用 ad-hoc 本地签名，没有 Developer ID / Apple 公证。
首次打开可能需要在“系统设置 → 隐私与安全性”中选择“仍要打开”；
本地重新签名命令、校验方法见包内 README 或该标签的 README。
不要用 sudo 启动整个 GUI；电池控制通过应用内按钮请求管理员授权。
不发布 PyPI 包。

## 测试范围与已知限制

- 已通过 Python 回归、原生策略/历史、演示控制器集成测试及应用构建检查。
- 本版按发布计划跳过真实电池切换、持续 CPU/GPU 压测和其他机器安装验证。
  macOS 15 是最低构建目标，不代表所有兼容系统均完成实机测试。
- 充电完成时间和空闲时间为估计；不保证准时充满或特定电池老化速度。
- 高负载会增加耗电与发热。历史记录保存在本机，默认不启用历史采集。

## 许可证与对应源码

组合应用按 GPL-3.0-only 分发，保留上游 Apache-2.0 和 SMC 原始许可声明。
许可证与第三方说明已随应用提供。`BatteryToolPlus-0.4.0-beta.1-source.tar.gz`
提供与二进制同一提交的完整项目源码及构建脚本；两份归档的校验值见 `SHA256SUMS`。

问题反馈：https://github.com/hcy2206/battery-tool-plus/issues
