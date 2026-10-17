# Battery Tool Plus macOS 管理应用

本说明适用于 [Battery Tool Plus](https://github.com/hcy2206/battery-tool-plus)，
项目由 [BatteryTool](https://github.com/oresttokovenko/battery-tool) fork 而来。
返回[项目首页](../README.md)或查看[开发指南](../CONTRIBUTING.md)。

对外名称为 **Battery Tool Plus**。为对应当前实现，下文命令中的 `BatteryTool.app`、
可执行文件 `BatteryTool`、数据目录及 `batterytool-control.lock` 仍沿用现有名称。

原生 SwiftUI 管理窗口与菜单栏入口，支持 Apple Silicon、macOS 15 及以上版本。
应用复用仓库中的 C/IOKit/SMC 接口；既有 Python 命令行继续可用。

## 构建与启动

安装 Xcode Command Line Tools 后，克隆本 fork 并构建：

```bash
git clone https://github.com/hcy2206/battery-tool-plus.git
cd battery-tool-plus
./scripts/build-macos.sh
open dist/BatteryTool.app
```

生成的是本机 ad-hoc 签名的开发应用。可以直接使用；尚未做 Developer ID 签名与公证，
不作为向其他电脑分发的安装包。不要使用 sudo 启动整个图形应用。

只查看界面和模拟模式切换（不写真实 SMC，不运行 CPU/GPU 负载）：

```bash
open dist/BatteryTool.app --args --demo
```

切换真实/演示模式前先退出已有应用，macOS 的 `open` 通常复用现有进程。
两种模式的设置和历史分别保存。

## 使用

1. 打开主窗口。默认是系统管理，不自动恢复上次运行的循环或压测任务。
2. 点击“授权电池控制”，完成 macOS 管理员授权。取消授权不启动任务。
3. 在“任务设置”调整电量上下限、健康度目标、CPU/GPU 档位、CPU 线程数。
   参数在下一次启动或切换到日常循环时生效，编辑过程中不会改变运行任务。
4. 选择模式：
   - **准备外出**：立即停止额外负载与强制放电，允许正常充电；保持直到手动切换。
   - **日常循环**：在电量上下限间充放电，不运行额外负载。
   - **定时压测**：在批准的窗口内循环，充电与放电阶段都运行设定负载。
5. 定时任务的目标时间必须在未来 24 小时内。截止目标：
   - **到点开始使用电脑**：到点停止负载，转入日常循环。
   - **到点携带电脑离开**：依据充电估算提前结束循环和负载，转入准备外出。
     默认目标电量为 100%。充电样本不足时使用手动预留时间（默认 120 分钟）；
     末段充电和系统策略可能导致估算偏差，不保证准时达到目标电量。
6. 默认在用户活动时暂停负载，持续空闲 300 秒后恢复，且不超出原批准窗口。
   可关闭此选项以保持压测。手动暂停则需手动恢复。
7. “停止并交还系统管理”始终停止负载、解除强制放电，包括设置表单尚未填写完成的情况。

关闭管理窗口后，应用和菜单栏继续运行；退出应用会停止负载并尝试恢复正常充电。
应用不自动设置开机启动，也不在重启后自动恢复高负载任务。

## 温控、电源与生命周期

- CPU 和 GPU 使用独立普通用户进程。CPU 档位控制计算占空比；GPU 使用短批次 Metal
  计算和批次间休息。档位不是精确的系统占用率；内存分配固定且有上限。
- 系统热状态为 fair 时负载减半，serious/critical 时停止负载并允许充电。
  热状态恢复后至少等待 60 秒再恢复负载。不绕过 macOS 温控。
- 拔电源、异常读数、达到目标健康度或电源写入失败时结束循环并尝试恢复充电。
- 低于 `max(3%, 充电下限/2)` 时结束压测并充电。允许充电十分钟后电量未明显增长时显示提示。
- 定时任务等待/执行期间阻止空闲系统睡眠，允许屏幕熄灭；不阻止合盖或主动睡眠。
  睡眠前停止负载并尝试恢复充电；唤醒后重新检查截止时间。
  如果权限服务已经因心跳过期退出，任务停止，需要重新授权和启动。
- 权限服务只支持充电、强制放电、心跳与退出，验证本地连接用户；不接受任意 SMC 键或 shell 命令。
  GUI 每两秒续租，失联约 12 秒后服务尝试恢复充电并退出。负载进程 stdin 关闭或六秒无心跳后退出。
- 权限服务当前采用按需管理员授权的短生命周期进程，不安装常驻 LaunchDaemon。
  正常退出时释放服务；系统断电、强杀权限服务或硬件拒绝写入无法保证执行恢复动作。
- 图形应用和 Python CLI 共享 `/var/run/batterytool-control.lock`，不允许同时改写电池控制。

## 空闲学习与历史

在“空闲推荐”开启本地记录。默认关闭活动记录；开启后每 30 秒保存时间、活动/空闲、
电量、充电与负载状态，不保存按键内容、窗口内容或应用名称。控制操作和错误事件单独记录。

- 保留最近 90 天的数据；预测使用最近 28 天、区分工作日与周末，并增加近期权重。
- 以 15 分钟为时段、每个日期一票，要求至少 3 天观察且空闲比例达到 80%；提前 15 分钟收尾。
- 数据不足时回退到配置的初始空闲区间，支持跨午夜。每次启动前显示推荐，由用户确认。
- 未运行、睡眠和采集间断的时间是未知，不填充为空闲。温控暂停不会作为“用户返回”的标签。
- 无键鼠操作不等于无人使用：观看视频、会议等可能被判断为空闲，可手动暂停。
- 历史页面展示最近 24 小时电量及最近 100 条事件，支持清除全部历史。
- 位置：`~/Library/Application Support/BatteryTool/`；演示模式使用 `BatteryTool-Demo/`。

## 验证与结构

```bash
./scripts/test-macos.sh             # 纯策略、预测和 SQLite 测试，无硬件访问
./scripts/test-macos-integration.sh # 演示控制器测试和 SwiftUI 离线渲染
uv run pytest                      # 原有 Python/CFFI 测试及控制器互斥测试
# 只编译正式 Metal 计算管线，不提交 GPU 计算：
dist/BatteryTool.app/Contents/MacOS/BatteryTool --check-gpu
```

离线页面预览输出到 `build/macos-integration/previews/`。

- `Sources/Policy.swift`：纯状态决策与设置校验。
- `Sources/Controller.swift`：任务编排、活动/温控观察、防睡眠与清理。
- `Sources/Hardware.swift`：SMC 封装及短生命周期权限服务。
- `Sources/Load.swift`：CPU/Metal 工作进程和心跳生命周期。
- `Sources/History.swift`：SQLite、空闲窗口推荐、无负载充电速度估计。
- `Sources/App.swift`：四页管理窗口及菜单栏。

原生管理核心使用 Swift，以直接接入 SwiftUI、Metal 与系统生命周期；Python CLI 保留。
两者共用 C 硬件层和互斥协议，而不是同时运行两个调度器。
