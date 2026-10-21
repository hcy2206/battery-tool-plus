# Battery Tool Plus v0.4.3

控制台改版：新增实时功率读数，并把数值指标与离散状态分开展示。

## 新增

- **实时功率。** 电池充放电功率（IOKit `Voltage` × `InstantAmperage`，与固件自报的 `BatteryPower` 一致，充电为正、放电为负）、适配器输入功率与系统负载功率（SMC `PowerTelemetryData`）。

## 变更

- **控制台分层。** 大卡片：电量 / 健康度 / 循环次数；小卡片：电池功率 / 适配器输入 / 系统负载；状态胶囊：模式、电源、充电、负载、热状态、熄屏、睡眠通知，自动换行，只在需要注意时着色（充电中绿、电池供电橙、热状态黄/红、风暴橙）；定时计划截止时间单独一行。

v0.4.2 的睡眠加固与 PushDeer 推送已包含在内，详见 CHANGELOG。

## 下载与安装

下载 `BatteryToolPlus-0.4.3-macos-arm64.dmg`，双击挂载后把 `Battery Tool Plus.app` 拖到旁边的 Applications 快捷方式上。
支持 Apple Silicon、macOS 15 及以上，无需 Python。

应用使用 ad-hoc 签名。首次打开时在"系统设置 → 隐私与安全性"点"仍要打开"，
或执行 `xattr -dr com.apple.quarantine "/Applications/Battery Tool Plus.app"`。
图形应用以普通用户运行，电池控制在应用内按需请求管理员授权。
