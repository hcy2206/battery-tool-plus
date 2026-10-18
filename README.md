# Battery Tool Plus

[![macOS](https://img.shields.io/badge/platform-macOS%2015%2B-lightgrey)](https://github.com/hcy2206/battery-tool-plus)
[![Apple Silicon](https://img.shields.io/badge/hardware-Apple%20Silicon-blue)](https://github.com/hcy2206/battery-tool-plus)
[![Python](https://img.shields.io/badge/Python-3.12-blue)](pyproject.toml)
[![License](https://img.shields.io/badge/license-GPL--3.0--only-green)](LICENSE)

**Battery Tool Plus** 是面向 Apple Silicon MacBook 的电池循环与计算负载管理工具，
由 [Orest Tokovenko 的 BatteryTool](https://github.com/oresttokovenko/battery-tool) fork 而来。
本项目在上游 Python/C 命令行工具的基础上，增加原生 macOS 管理窗口、CPU/GPU 负载、
模式切换、定时任务、空闲时间推荐与本地历史记录。

项目仓库：[hcy2206/battery-tool-plus](https://github.com/hcy2206/battery-tool-plus)。
问题反馈与功能建议请提交到[本仓库 Issues](https://github.com/hcy2206/battery-tool-plus/issues)。

## 功能

| 功能 | 行为 |
| --- | --- |
| 图形管理 | 控制台、任务设置、空闲推荐、历史记录四个页面，附带菜单栏快捷入口 |
| 准备外出 | 停止额外负载和强制放电，允许正常充电，等待手动切换 |
| 日常循环 | 在电量上下限之间循环充放电，不施加 CPU/GPU 负载 |
| 定时压测 | 在确认的时间窗口内循环，充电与放电阶段均运行配置的 CPU/Metal GPU 负载 |
| 两类截止目标 | 到点开始使用电脑，或提前预留充电时间以便携带电脑离开 |
| 自动暂停与温控 | 用户活动时暂停，持续空闲后恢复；系统热状态升高时降载或暂停 |
| 空闲推荐 | 从初始空闲时段起步，根据本地活动记录推荐时间窗口，每次启动前由用户确认 |
| 历史与状态 | 电量、健康度、循环次数、电源状态、电量曲线与操作事件 |
| 兼容命令行 | 保留原有 Python CLI、JSON 日志和模拟硬件测试 |

## 环境与命名

- 原生应用：Apple Silicon、macOS 15 及以上、Xcode Command Line Tools。
- Python CLI：macOS、Apple Silicon、Python 3.12、[uv](https://docs.astral.sh/uv/)。
- 真实电池控制依赖 IOKit/SMC，模拟后端可用于不接触真实硬件的验证。

对外项目名称为 **Battery Tool Plus**。当前代码仍保留以下兼容名称；它们不是新的下载来源：

| 项目 | 当前实际名称 |
| --- | --- |
| 仓库 | `hcy2206/battery-tool-plus` |
| Python 包 / CLI 命令 | `battery-tool` |
| Python 模块 | `batterytool` |
| 原生应用文件 | `dist/BatteryTool.app` |
| 原生应用可执行文件 | `BatteryTool.app/Contents/MacOS/BatteryTool` |
| 本地数据目录 | `~/Library/Application Support/BatteryTool/` |

上游 PyPI 包也使用 `battery-tool` 名称。**直接执行 `uv tool install battery-tool` 会选择该包名对应的 PyPI 发布物，不能据此获得本 fork 的新增功能。** 请按下面的源码方式构建或安装。

## 下载与安装（测试版）

从 [GitHub Releases](https://github.com/hcy2206/battery-tool-plus/releases) 下载
`BatteryToolPlus-0.4.0-beta.1-macos-arm64.zip`，解压后将 `BatteryTool.app` 拖入“应用程序”。
预编译应用无需安装 Python 或 Xcode。最低构建目标为 macOS 15，限 Apple Silicon；
本测试版尚未完成真实电池切换、持续负载及不同系统版本的实机验证。
不发布 PyPI 包。Release 同时提供对应源码与 `SHA256SUMS`，下载后可在同一目录验证：

```bash
shasum -a 256 -c SHA256SUMS
```

该命令检查校验表中的应用 ZIP 和源码归档，两者均需下载。
应用已经 **ad-hoc 本地签名**，没有 Developer ID，也未经 Apple 公证。
首次打开若提示无法验证开发者，确认来自本仓库且校验值正确后，可按
[Apple 官方说明](https://support.apple.com/102445)，在“系统设置 → 隐私与安全性”
中选择“仍要打开”。不要全局关闭 Gatekeeper。

### 本地重新签名（可选）

适用于自行构建、修改后需要重新签名的应用。先退出应用，对自己有写入权限的路径执行：

```bash
APP_PATH="/Applications/BatteryTool.app"
codesign --force --deep --sign - "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
open "$APP_PATH"
```

若该路径没有写权限，可以先把应用复制到 `~/Applications/` 并调整 `APP_PATH`。
`--sign -` 使用 ad-hoc 签名，不需要证书。它不认证开发者身份、不等同于公证，
也不会自动移除下载隔离或保证通过 Gatekeeper；仍可能需要上述系统设置中的允许操作。
下载内容若被系统报告为恶意软件，应停止打开并核实来源，而非反复重新签名。

## 获取源码

```bash
git clone https://github.com/hcy2206/battery-tool-plus.git
cd battery-tool-plus
```

## 原生 macOS 管理应用

```bash
./scripts/build-macos.sh
open dist/BatteryTool.app
```

应用默认交由系统管理电池，不自动启动循环或高负载。需要电池控制时，
在窗口点击“授权电池控制”，再选择模式或确认定时任务。

仅查看界面和模拟模式切换，不写入真实电池，也不运行计算负载：

```bash
open dist/BatteryTool.app --args --demo
```

切换真实与演示模式前先退出已有应用。当前构建为本机开发签名版本，尚未进行 Developer ID 公证。
完整使用方式、权限服务行为和限制见 [macOS 管理应用说明](macos/README.md)。

## 从本 fork 安装 Python CLI

在克隆后的仓库目录中执行：

```bash
uv tool install --python 3.12 --no-config .
battery-tool --status
```

`--no-config` 让安装使用隔离构建，不沿用仓库专供可编辑开发环境使用的 uv 配置。
如本地已装有同名包，应先确认现有安装来源，再按需使用 `--force` 替换。

开始真实电池循环前连接适配器，检查 macOS 的充电策略是否与循环控制冲突，
并确保电脑不会在任务中途进入睡眠。原生定时任务自带防空闲睡眠控制，旧 CLI 没有此功能。

```bash
sudo "$(command -v battery-tool)"
```

图形应用的已授权电源服务与 CLI 通过互斥锁避免同时控制电池。

### CLI 参数

| 参数 | 作用 | 默认值 |
| --- | --- | --- |
| `--target-health` | 健康度达到或低于此值时停止循环 | `79` |
| `--max-charge` | 电量达到此值时开始放电 | `95` |
| `--min-charge` | 电量降至此值时恢复充电 | `5` |
| `--interval` | 轮询间隔，单位为秒 | `60` |
| `--log-file` | 将 JSON 日志同时写入文件 | 无 |
| `--status` | 只读取状态并退出，不写入电池控制 | `False` |

CLI 要求 `0 <= target-health <= 100`、`1 <= min-charge < max-charge <= 100`，
轮询间隔至少为一秒。原生应用的默认循环区间为 20%–90%，请在任务设置中调整。

CLI 在启动时明确设置充电状态；拔电源、无效读数或 SMC 写入失败会停止循环并尝试恢复充电。
Ctrl+C 也会执行恢复。运行错误返回退出码 1，参数错误返回退出码 2；
恢复失败记录为 `cleanup_failed`。断电或强制终止可能无法执行清理。

## 开发与文档

- [贡献与开发指南](CONTRIBUTING.md)：开发环境、检查命令、模拟后端及 fork 发布注意事项。
- [原生管理应用说明](macos/README.md)：模式、定时任务、负载、预测与数据保存。
- [发布指南](RELEASING.md)：版本、打包、签名与 GitHub Release 操作。
- [变更记录](CHANGELOG.md)：本 fork 的版本变更，以及保留的上游历史。

## 上游来源与致谢

本项目保留上游作者与第三方源码的署名、许可声明及历史记录。
组合应用按 **GPL-3.0-only** 分发，见 [LICENSE](LICENSE)。上游 Apache-2.0 许可原文保存在
[LICENSES/Apache-2.0.txt](LICENSES/Apache-2.0.txt)，SMC 文件保留 GPL-2.0-or-later 声明；
本发行版选择 GPLv3 进行组合分发。详情与对应源码说明见[第三方声明](THIRD_PARTY_NOTICES.md)。

- [BatteryTool](https://github.com/oresttokovenko/battery-tool)，作者 [Orest Tokovenko](https://github.com/oresttokovenko)。
  [原作者的项目背景文章](https://oresttokovenko.com/blog/macbook-battery-replacement/)介绍了上游的起源。
- [battery.sh](https://github.com/actuallymentor/battery/blob/main/battery.sh)，作者 [Actually Mentor](https://github.com/actuallymentor)：上游电池管理逻辑的参考。
- [smc-command](https://github.com/hholtmann/smcFanControl/tree/master/smc-command)，作者 [hholtmann](https://github.com/hholtmann)：SMC 通信基础。
- [bclm](https://github.com/zackelia/bclm)：充电控制 SMC 键的研究参考。
