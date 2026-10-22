# 开发指南

本指南适用于 [hcy2206/battery-tool-plus](https://github.com/hcy2206/battery-tool-plus)，
是 [Orest Tokovenko 的 BatteryTool](https://github.com/oresttokovenko/battery-tool) 的一个 fork。
Issue 和 PR 请提交到本 fork，而不是上游项目。请保留上游署名、第三方许可声明和历史变更记录链接。

对外项目名为 **Battery Tool Plus**，但 Python 分发包、CLI 命令、模块名和原生应用的实际标识符与此不同；
命令和路径中请使用实际标识符，完整对照表见[使用指南的名称与标识符](USER_GUIDE.md#名称与标识符)。

## 环境要求

- macOS 15 或更高版本（Apple Silicon）
- Xcode Command Line Tools（Swift、Clang、macOS SDK）
- Python 3.12
- [uv](https://docs.astral.sh/uv/)
- [just](https://github.com/casey/just)
- `clang-format` 和 `clang-tidy`（C 代码格式化与静态检查）：

  ```bash
  brew install clang-format llvm
  ```

## 初始化

```bash
git clone https://github.com/hcy2206/battery-tool-plus.git
cd battery-tool-plus
uv sync --all-groups --no-install-project
uv sync --all-groups
```

第一次同步只安装 Meson、meson-python 和 Ninja 到项目环境；第二次才以非隔离模式构建可编辑包，
这样后续导入会针对仍然存在的工具重新编译，而不是针对已被删除的临时隔离环境。

要构建发布用的 wheel，使用隔离环境、不依赖本地开发配置：

```bash
uv build --no-config --wheel
```

## 检查与测试

```bash
just check            # 全部检查（Python + C）
just python-check     # 格式检查 + lint + 类型检查
just c-check           # 格式检查 + lint + C 测试
just c-test-ci         # 排除硬件相关测试的 C 测试
```

原生 macOS 管理应用的检查：

```bash
./scripts/test-macos.sh             # 策略、预测和 SQLite 测试，无硬件访问
./scripts/test-macos-integration.sh # 演示控制器、IPC、工作进程生命周期和 SwiftUI 离屏渲染
uv run pytest                       # Python/CFFI 回归与控制器互斥测试
"dist/Battery Tool Plus.app/Contents/MacOS/BatteryTool" --check-gpu   # 只编译 Metal 管线
swift scripts/make-icon.swift macos/AppIcon.icns              # 重新生成应用图标
```

离屏渲染的页面预览输出到 `build/macos-integration/previews/`。

CI 在 push 到 `main` 和 pull request 时自动运行上述 Python 检查、C 测试、原生测试与应用构建。

## 代码结构

- `c/`：硬件访问层（SMC、电源信息）及对应的文件后端模拟实现（`*_fake.c`）
- `src/batterytool/`：Python CLI 与循环策略
- `macos/Sources/*.swift`：原生管理应用
  - `Policy.swift`：纯状态决策与设置校验
  - `Controller.swift`：任务编排、活动/温控观察、防睡眠与清理
  - `Hardware.swift`：SMC 封装与短生命周期电源服务
  - `Load.swift`：CPU/Metal 工作进程与心跳生命周期
  - `History.swift`：SQLite、空闲窗口推荐、无负载充电速度估计
  - `App.swift`：四页管理窗口与菜单栏
- `scripts/`：构建、打包与原生测试脚本

原生部分使用 Swift 直接接入 SwiftUI、Metal 和系统生命周期；与 Python CLI 共用 C 硬件层和互斥协议。

## C 代码规范

C 源码位于 `c/`。第三方文件 `smc.c`/`smc.h` 不参与格式化和 lint，其他 C 文件都要通过
`clang-format` 和 `clang-tidy` 检查。

与 SMC 或 IOKit 通信的硬件相关 C 测试在 meson 中标记为 `suite: 'hardware'`，CI 中会被跳过。

## 模拟后端

Python 电池回归测试使用文件后端的模拟实现，而不是真实硬件。软件包会构建**两个**暴露相同 API 的扩展模块：

- `iokit_wrapper`：真实实现，访问 IOKit/SMC
- `iokit_wrapper_fake`：文件后端模拟实现（`c/smc_fake.c`、`c/power_sources_fake.c`）

设置 `BATTERYTOOL_FAKE=1` 会让 `battery.py` 在导入时绑定模拟实现，于是整个软件包（包括 CLI）
都会端到端运行真实代码路径，包括 CFFI 字节编解码，以及从 `CHIE` 到 `CH0J` 的 Tahoe 回退逻辑。

### 模拟实现的驱动方式

模拟实现在每次调用时读取 `$BATTERYTOOL_FAKE_DIR`，所有状态保存在该目录下的文件中：

| 文件 | 作用 |
|------|------|
| `smc_keys` | 每行一条 `KEY <字节长度> <十六进制值>`。只有这些键"存在"；读写其他键会像真实硬件一样失败 |
| `battery_script` | 每行一条 `current max design cycle is_charging is_plugged_in`。每次 `FetchBatteryInfo` 轮询消费下一行，最后一行会重复 |
| `smc_writes.log` | 监听记录：每次**成功**的写入都以 `KEY=十六进制值` 的形式追加。测试断言依赖这个文件 |

未设置 `BATTERYTOOL_FAKE_DIR` 时模拟实现处于失效状态（任何调用都会失败），因此测试套件中的任何
代码路径都不会意外写入真实 SMC。

### 编写 Python 测试

使用 `tests/conftest.py` 中的 `hw` fixture。它会为每个测试把模拟实现指向一个全新的临时目录，
并以方法形式暴露上面三个文件。给循环传 `interval=0` 可以避免它们真的 sleep：

```python
def test_tahoe_disables_above_max(hw):
    hw.set_keys({"CHTE": "00000000", "CHIE": "08"})  # 存在的键
    hw.script((96, 100, 100, 10, 1, 1), (79, 79, 100, 10, 1, 1))

    tahoe_loop(target_health=79, max_charge=95, min_charge=5, interval=0, logger=setup_logging())

    assert hw.writes() == ("CHTE=01000000", "CHIE=08", "CHTE=00000000", "CHIE=00")
```

要触发 Tahoe 回退逻辑，在 `set_keys` 中省略 `CHIE`。这样写入会像真实硬件一样失败，循环会回退到 `CH0J`。

自定义的 pytest 标记（例如 `apple_silicon`）在 `pyproject.toml` 中注册，并在 `conftest.py` 的
`pytest_collection_modifyitems` 中应用，不要在测试文件内直接写 `skipif` 逻辑。

### 编写 C 测试

模拟实现本身在 `c/tests/test_smc_fake.c` 中用 cmocka 测试。每个测试通过 `FAKE_TEST(...)` 宏获得
全新的模拟目录（每测试独立的 setup/teardown）。这些测试不带 `hardware` suite 标签，因此在支持的
macOS 构建主机（包括 CI）上无需 SMC 访问即可运行。

## 提交信息

本项目使用 [Conventional Commits](https://www.conventionalcommits.org/) 规范提交历史。版本号显式管理，
详见 [发布指南](RELEASING.md)。

每次提交到 `main` 都必须遵循以下格式：

```
type: 简短描述
```

### 类型

| 类型       | 用途                         | 版本递增 |
|------------|------------------------------|----------|
| `feat`     | 新功能                       | Minor    |
| `fix`      | 修复 bug                     | Patch    |
| `docs`     | 仅文档改动                   | 无       |
| `ci`       | CI/CD 改动                   | 无       |
| `refactor` | 既非修复也非新增的代码改动   | 无       |
| `test`     | 新增或更新测试               | 无       |
| `chore`    | 维护性改动（依赖、配置等）   | 无       |

破坏性改动在类型后加 `!`，或在提交正文中写 `BREAKING CHANGE:`：

```
feat!: redesign SMC key API
```

### 示例

```
feat: add tahoe SMC key support for macOS 15.7+
fix: prevent double-close of SMC connection
ci: skip hardware-dependent tests on CI runners
docs: add contributing guidelines
refactor: extract battery info fetch into wrapper function
test: add cmocka test for SmcReadKey
```

## 发布

版本号、打包、签名和发布流程见[发布指南](RELEASING.md)。
