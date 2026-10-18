# Battery Tool Plus

[![macOS](https://img.shields.io/badge/platform-macOS%2015%2B-lightgrey)](https://github.com/hcy2206/battery-tool-plus)
[![Apple Silicon](https://img.shields.io/badge/hardware-Apple%20Silicon-blue)](https://github.com/hcy2206/battery-tool-plus)
[![Python](https://img.shields.io/badge/Python-3.12-blue)](pyproject.toml)
[![License](https://img.shields.io/badge/license-GPL--3.0--only-green)](LICENSE)

**Battery Tool Plus** 是 Apple Silicon MacBook 的电池循环与计算负载管理工具。
它在 [Orest Tokovenko 的 BatteryTool](https://github.com/oresttokovenko/battery-tool) 命令行工具之上，
加入了原生 macOS 管理应用：图形控制台、CPU/GPU 负载、模式切换、定时任务、空闲时段推荐和本地历史记录。

仓库：[hcy2206/battery-tool-plus](https://github.com/hcy2206/battery-tool-plus) ·
反馈：[Issues](https://github.com/hcy2206/battery-tool-plus/issues)

## 功能

| 功能 | 行为 |
| --- | --- |
| 图形管理 | 控制台、任务设置、空闲推荐、历史记录四个页面，菜单栏显示电量与模式 |
| 准备外出 | 停止负载和强制放电，恢复正常充电，直到你手动切换 |
| 日常循环 | 在电量上下限之间自动充放电，不施加额外负载 |
| 定时压测 | 在你确认的时间窗口内循环，充电与放电阶段都运行设定的 CPU / Metal GPU 负载 |
| 两类截止目标 | 到点开始使用电脑，或到点带走电脑（提前预留充电时间） |
| 自动暂停与温控 | 使用电脑时暂停负载，持续空闲后恢复；系统热状态升高时自动降载或暂停 |
| 空闲推荐 | 从你设定的初始空闲时段起步，按本地活动记录学习推荐时间窗口，每次启动前由你确认 |
| 历史与状态 | 电量、健康度、循环次数、电源状态、24 小时电量曲线与操作事件 |
| 命令行 | 保留上游 Python CLI、JSON 日志和模拟硬件测试 |

## 环境与命名

- 原生应用：Apple Silicon、macOS 15 或更高版本。从源码构建需要 Xcode Command Line Tools。
- Python CLI：Apple Silicon、Python 3.12、[uv](https://docs.astral.sh/uv/)。
- 电池控制通过 IOKit/SMC 完成；测试使用文件模拟后端，不触碰真实硬件。

对外名称为 **Battery Tool Plus**，代码中的标识符沿用上游：

| 项目 | 实际名称 |
| --- | --- |
| 仓库 | `hcy2206/battery-tool-plus` |
| Python 包 / CLI 命令 | `battery-tool` |
| Python 模块 | `batterytool` |
| 应用文件 | `BatteryTool.app`（显示名 Battery Tool Plus） |
| 本地数据目录 | `~/Library/Application Support/BatteryTool/` |

PyPI 上的 `battery-tool` 是上游包，不包含本项目的图形应用与新增功能。请从 GitHub Releases 下载应用，或按下文从源码安装。

## 下载与安装

从 [GitHub Releases](https://github.com/hcy2206/battery-tool-plus/releases) 下载
`BatteryToolPlus-<版本>-macos-arm64.zip`，解压后把 `BatteryTool.app` 拖进“应用程序”。无需安装 Python 或 Xcode。

Release 同时提供对应源码归档和 `SHA256SUMS`，把两者放在同一目录即可校验：

```bash
shasum -a 256 -c SHA256SUMS
```

应用使用 ad-hoc 签名，没有 Developer ID，也没有经过 Apple 公证。首次打开时 macOS 会提示无法验证开发者：
打开“系统设置 → 隐私与安全性”，在页面底部点“仍要打开”即可（[Apple 说明](https://support.apple.com/102445)）。
不需要关闭 Gatekeeper。

自行修改并重新构建后，用同样的 ad-hoc 方式签名即可运行：

```bash
APP_PATH="/Applications/BatteryTool.app"
codesign --force --deep --sign - "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
open "$APP_PATH"
```

## 从源码构建

```bash
git clone https://github.com/hcy2206/battery-tool-plus.git
cd battery-tool-plus
./scripts/build-macos.sh
open dist/BatteryTool.app
```

应用启动后默认交给系统管理电池。点击“授权电池控制”完成一次管理员授权，然后选择模式或确认定时任务。

演示模式只渲染界面和模拟模式切换，不写入电池，也不运行负载：

```bash
open dist/BatteryTool.app --args --demo
```

切换真实与演示模式前先退出正在运行的应用。完整说明见 [macOS 管理应用](macos/README.md)。

## Python CLI

```bash
uv tool install --python 3.12 --no-config .
sudo "$(command -v battery-tool)"
```

CLI 会直接写 SMC，需要 root；非 root 运行会明确提示使用 sudo。`--status` 只读取状态，不需要 root。
开始循环前连接电源适配器。图形应用的电源服务与 CLI 使用同一把互斥锁，二者不会同时控制电池。

| 参数 | 作用 | 默认值 |
| --- | --- | --- |
| `--target-health` | 健康度降到该值时停止循环 | `79` |
| `--max-charge` | 电量达到该值时开始放电 | `95` |
| `--min-charge` | 电量降到该值时恢复充电 | `5` |
| `--interval` | 轮询间隔（秒） | `60` |
| `--log-file` | 同时把 JSON 日志写入文件 | 无 |
| `--status` | 读取状态后退出 | `False` |

约束：`0 <= target-health <= 100`、`1 <= min-charge < max-charge <= 100`、间隔至少 1 秒。
CLI 启动时显式设置充电状态；拔电源、读数无效、SMC 写入失败或 Ctrl+C 都会停止循环并恢复充电。
运行错误退出码 1，参数错误退出码 2。原生应用默认循环区间为 20%–90%，可在任务设置中调整。

## 开发与文档

- [贡献与开发指南](CONTRIBUTING.md)：开发环境、检查命令、模拟后端。
- [macOS 管理应用](macos/README.md)：模式、定时任务、负载、推荐与数据存储。
- [发布指南](RELEASING.md)：版本、打包、签名与 GitHub Release。
- [变更记录](CHANGELOG.md)。

## 来源与致谢

组合应用按 **GPL-3.0-only** 分发（[LICENSE](LICENSE)）。上游 Apache-2.0 许可原文保存在
[LICENSES/Apache-2.0.txt](LICENSES/Apache-2.0.txt)，SMC 文件保留 GPL-2.0-or-later 声明；详见[第三方声明](THIRD_PARTY_NOTICES.md)。

- [BatteryTool](https://github.com/oresttokovenko/battery-tool)，作者 [Orest Tokovenko](https://github.com/oresttokovenko)，
  [项目背景文章](https://oresttokovenko.com/blog/macbook-battery-replacement/)。
- [battery.sh](https://github.com/actuallymentor/battery/blob/main/battery.sh)，作者 [Actually Mentor](https://github.com/actuallymentor)。
- [smc-command](https://github.com/hholtmann/smcFanControl/tree/master/smc-command)，作者 [hholtmann](https://github.com/hholtmann)。
- [bclm](https://github.com/zackelia/bclm)：充电控制 SMC 键的研究参考。
