# Battery Tool Plus macOS 管理应用

原生 SwiftUI 管理窗口与菜单栏入口，运行于 Apple Silicon、macOS 15 及以上。
应用直接复用仓库中的 C/IOKit/SMC 层；Python CLI 继续可用。
返回[项目首页](../README.md)或查看[开发指南](../CONTRIBUTING.md)。

对外名称为 **Battery Tool Plus**；`BatteryTool.app`、可执行文件 `BatteryTool`、数据目录和
`batterytool-control.lock` 沿用上游标识符。

## 构建与启动

```bash
git clone https://github.com/hcy2206/battery-tool-plus.git
cd battery-tool-plus
./scripts/build-macos.sh
open dist/BatteryTool.app
```

构建产物为 ad-hoc 签名的应用，直接可用。通过 GitHub Release 分发的版本首次打开需要在
“系统设置 → 隐私与安全性”点一次“仍要打开”，见 [README](../README.md#下载与安装)。
图形应用本身以普通用户运行，不要用 sudo 启动；电池控制在应用内按需授权。

演示模式只渲染界面和模拟模式切换，不写 SMC，也不运行负载：

```bash
open dist/BatteryTool.app --args --demo
```

真实与演示模式的设置和历史分开保存；切换前先退出正在运行的应用。

## 使用

1. 打开主窗口。默认为系统管理，不自动恢复上次的任务。
2. 点击“授权电池控制”，完成一次管理员授权。
3. 在“任务设置”调整电量上下限、健康度目标、CPU/GPU 档位和 CPU 线程数。
   参数在下次启动任务或切换到日常循环时生效；编辑过程中不影响运行中的任务。
4. 选择模式：
   - **准备外出**：停止负载和强制放电，恢复正常充电，保持到你手动切换。
   - **日常循环**：在电量上下限之间充放电，不运行负载。
   - **定时压测**：在确认的窗口内循环，充电与放电阶段都运行设定负载。
5. 定时任务的目标时间在未来 24 小时内。截止目标有两种：
   - **到点开始使用电脑**：到点停止负载，转入日常循环。
   - **到点携带电脑离开**：按无负载充电记录估算所需充电时间，提前结束压测并转入准备外出，
     默认目标电量 100%。没有足够记录时使用你设定的预留时间（默认 120 分钟）。
6. 默认在使用电脑时暂停负载，持续空闲 300 秒后恢复，并且不超出已确认的窗口。
   关闭该选项可保持压测。手动暂停需要手动恢复。
7. “停止并交还系统管理”随时可用，立即停止负载并解除强制放电，即使设置表单里有无效输入。

关闭窗口后应用与菜单栏继续运行；退出应用会停止负载并恢复正常充电。
应用不设置开机启动，也不在重启后自动恢复任务。

## 负载、温控与生命周期

- CPU 和 GPU 负载各自运行在独立的普通用户进程中，以 user-initiated QoS 调度，
  因此 CPU 负载落在性能核上。CPU 档位控制计算占空比；GPU 使用短批次 Metal 计算加批次间休息。
  档位是工作比例，不是系统占用率读数。
- 系统热状态 fair 时负载减半；serious/critical 时停止负载并允许充电，恢复后等待 60 秒再加载。
  macOS 温控始终优先。
- 拔电源、读数异常、达到目标健康度或电源写入失败时结束任务并恢复充电。
  电量低于 `max(3%, 充电下限/2)` 时结束压测并充电。允许充电十分钟后电量没有上升会给出提示。
- 定时任务期间阻止空闲系统睡眠，允许屏幕熄灭；不阻止合盖或主动睡眠。
  睡眠前停止负载并恢复充电，唤醒后重新检查截止时间。
- 历史记录写入失败只显示提示，不影响任务运行。
- 电源服务是按需授权的短生命周期 root 进程，只接受充电、强制放电、心跳和退出四个命令，
  并校验连接方的用户身份；不接受任意 SMC 键或 shell 命令。图形应用每 2 秒续租，
  失联 12 秒后服务恢复充电并退出。负载进程在 stdin 关闭或 15 秒无心跳后退出。
- 图形应用与 Python CLI 共用 `/var/run/batterytool-control.lock`，同一时间只有一个控制器写电池。
- SMC 键按固件自动选择：充电抑制用 CHTE（macOS 15.7–26）或 CH0B/CH0C（更早），放电用 CHIE（否则 CH0J/CH0I）。
  macOS 27 及 15.8 / 26.7 更新后的固件删除了充电抑制键，循环只靠 CHIE 切断/恢复适配器完成，充电阶段由系统正常充电。

## 空闲学习与历史

在“空闲推荐”页开启本地记录（默认关闭）。开启后每 30 秒记录时间、活动/空闲、电量、充电与负载状态；
不记录按键、窗口或应用名称。控制操作和错误事件始终记录。

- 保留最近 90 天；推荐使用最近 28 天，区分工作日与周末，近期数据权重更高。
- 以 15 分钟为时段、每个日期一票，至少 3 天观察且空闲比例达到 80% 的时段才会推荐；窗口提前 15 分钟收尾，
  并限制在 24 小时任务上限内。
- 数据不足时回退到你设定的初始空闲区间，支持跨午夜。推荐只在你确认后启动，不会自行扩大窗口。
- 应用未运行、睡眠和采集间断的时间记为未知，不当作空闲。温控暂停不会被当作用户活动。
- 没有键鼠输入的活动（看视频、开会）会被判断为空闲，需要时手动暂停。
- 历史页展示最近 24 小时电量曲线和最近 100 条事件，可一键清除。
- 数据位置：`~/Library/Application Support/BatteryTool/`；演示模式使用 `BatteryTool-Demo/`。

## 验证与结构

```bash
./scripts/test-macos.sh             # 策略、预测和 SQLite 测试，无硬件访问
./scripts/test-macos-integration.sh # 演示控制器、IPC、工作进程生命周期和 SwiftUI 离屏渲染
uv run pytest                      # Python/CFFI 回归与控制器互斥测试
dist/BatteryTool.app/Contents/MacOS/BatteryTool --check-gpu   # 只编译 Metal 管线
swift scripts/make-icon.swift macos/AppIcon.icns              # 重新生成应用图标
```

离屏渲染的页面预览输出到 `build/macos-integration/previews/`。

- `Sources/Policy.swift`：纯状态决策与设置校验。
- `Sources/Controller.swift`：任务编排、活动/温控观察、防睡眠与清理。
- `Sources/Hardware.swift`：SMC 封装与短生命周期电源服务。
- `Sources/Load.swift`：CPU/Metal 工作进程与心跳生命周期。
- `Sources/History.swift`：SQLite、空闲窗口推荐、无负载充电速度估计。
- `Sources/App.swift`：四页管理窗口与菜单栏。

原生部分使用 Swift 直接接入 SwiftUI、Metal 和系统生命周期；与 Python CLI 共用 C 硬件层和互斥协议。
