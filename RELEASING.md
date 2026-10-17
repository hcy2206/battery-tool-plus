# 发布 macOS 应用

仅通过 GitHub Releases 发布，不发布 PyPI。当前首版为 `v0.4.0-beta.1`，
使用 ad-hoc 签名，不做 Developer ID 签名或公证。

## 版本与准备

- 同步修改 `pyproject.toml`、`meson.build`、`uv.lock` 的项目版本，例如 `0.4.0b1`。
- 标签和附件使用 `v0.4.0-beta.1` / `0.4.0-beta.1`。
- 构建脚本映射为 CFBundleShortVersionString `0.4.0`、CFBundleVersion `1`。
  后续 beta 增加 b 后的数字；正式版前应调整构建号策略使其持续递增。
- 更新 CHANGELOG、RELEASE_NOTES 和 README 下载版本。
- 保留 LICENSE、LICENSES、THIRD_PARTY_NOTICES，源码和应用须来自同一提交。
- 执行 `./scripts/test-macos.sh`、`./scripts/test-macos-integration.sh` 和 `uv run pytest`。
  实机检查独立于自动测试；未完成时必须在发布说明中明确列出。

## 本地构建与发布

先提交全部改动，保持工作区干净，再运行：

```bash
./scripts/package-macos.sh
(cd dist/release && shasum -a 256 -c SHA256SUMS)
git tag -a v0.4.0-beta.1 -m 'Battery Tool Plus v0.4.0-beta.1'
git push origin main v0.4.0-beta.1
gh release create v0.4.0-beta.1 dist/release/* \
  --verify-tag --draft --prerelease \
  --title 'Battery Tool Plus v0.4.0-beta.1' --notes-file RELEASE_NOTES.md
```

脚本构建并验证签名和 plist，生成应用 ZIP、对应 HEAD 的源码 tar.gz 和 SHA256SUMS。
`BUILD_COMMIT.txt` 记录二进制来源。后续发布前使用空的 `dist/release` 目录，
避免把上一版本附件一并上传；不得覆盖已经发布的标签和文件。
核对草稿中的版本、源码、附件及说明后：

```bash
gh release edit v0.4.0-beta.1 --draft=false --prerelease --latest=false
```

## GitHub Actions 方式

推送版本标签后，在 Actions 中手动运行 `macOS Release`，输入该标签。
工作流在 macOS 15 ARM runner 上校验标签与版本，执行策略测试、打包并创建预发布草稿。
同一版本不要同时使用本地和 Actions 两条发布路径；已有 Release 时创建步骤会失败，
以避免静默覆盖附件。需要发布时审核草稿后手动公开。

首次发布使用本地构建；Actions 路径是后续可用流程，并不代表已经在远端运行验证。
现有 CI 仍由 pull request 触发，直接 push 不代表 CI 已通过。

## 签名、许可证和参考

本地签名与 Gatekeeper 操作见 [README](README.md#下载与安装测试版)。
签名验证不等于 Apple 公证或实机验证。
组合应用采用 GPL-3.0-only，保留原始组件许可，详见 [第三方声明](THIRD_PARTY_NOTICES.md)。

- [GitHub CLI Release](https://cli.github.com/manual/gh_release_create)
- [Apple 首次打开说明](https://support.apple.com/102445)
- [Apache 与 GPL 兼容性](https://www.apache.org/licenses/GPL-compatibility)
- [GNU GPLv3](https://www.gnu.org/licenses/gpl-3.0.html)
