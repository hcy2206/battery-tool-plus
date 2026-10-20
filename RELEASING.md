# 发布 macOS 应用

通过 GitHub Releases 发布应用，不发布 PyPI 包。应用使用 ad-hoc 签名。

## 版本与准备

- 同步修改 `pyproject.toml`、`meson.build` 的版本（正式版 `0.4.0`，预发布 `0.4.1b1`），运行 `uv lock` 更新锁文件。
- 标签和附件使用 `v<版本>` / `<版本>`：正式版 `v0.4.0` / `0.4.0`，预发布 `v0.4.1-beta.1` / `0.4.1-beta.1`；下文以 `v0.4.0` 为例。
- 构建脚本把版本映射为 CFBundleShortVersionString（去掉 `bN` 后缀），CFBundleVersion 取提交数，随每次提交递增。
- 更新 CHANGELOG、RELEASE_NOTES 和 README。
- 运行 `./scripts/test-macos.sh`、`./scripts/test-macos-integration.sh` 和 `uv run pytest`。
  实机验证单独进行，结果写入发布说明。

## 本地构建与发布

提交全部改动后运行：

```bash
./scripts/package-macos.sh
(cd dist/release && shasum -a 256 -c SHA256SUMS)
git tag -a v0.4.0 -m 'Battery Tool Plus v0.4.0'
git push origin main v0.4.0
gh release create v0.4.0 dist/release/* \
  --verify-tag --draft \
  --title 'Battery Tool Plus v0.4.0' --notes-file RELEASE_NOTES.md
```

脚本构建应用、校验签名、plist 和部署目标，生成应用 DMG（含 Applications 快捷方式，挂载校验后再推出）、对应 HEAD 的源码 tar.gz 和 SHA256SUMS；
`BUILD_COMMIT.txt` 记录构建提交。发布新版本前清空 `dist/release`，避免上传旧附件；
已发布的标签和文件不要覆盖。预发布版本加 `--prerelease`。核对草稿后公开：

```bash
gh release edit v0.4.0 --draft=false --latest   # 预发布：--prerelease --latest=false
```

## GitHub Actions 方式

推送版本标签后，在 Actions 手动运行 `macOS Release` 并输入该标签。
工作流在 macOS 15 ARM runner 上校验标签与版本、运行策略测试、打包并创建草稿（含 `-beta.` 的标签标为预发布）。
同一版本只走一条发布路径；Release 已存在时创建步骤会失败，不会覆盖附件。

CI 在 push 到 main 和 pull request 时运行，覆盖 Python 检查、C 测试、原生测试、集成测试与应用构建。

## 签名、许可证和参考

本地签名与 Gatekeeper 操作见 [README](README.md#下载与安装)。
组合应用采用 GPL-3.0-only，保留原始组件许可，详见[第三方声明](THIRD_PARTY_NOTICES.md)。

- [GitHub CLI Release](https://cli.github.com/manual/gh_release_create)
- [Apple 首次打开说明](https://support.apple.com/102445)
- [Apache 与 GPL 兼容性](https://www.apache.org/licenses/GPL-compatibility)
- [GNU GPLv3](https://www.gnu.org/licenses/gpl-3.0.html)
