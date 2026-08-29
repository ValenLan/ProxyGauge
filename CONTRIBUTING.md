# 为 ProxyGauge 贡献

感谢你愿意改进 ProxyGauge。项目同时包含 macOS、Windows、系统防火墙和安装器代码；提交前请明确改动影响的平台与权限边界。

## 开始之前

- Bug、功能建议和普通问题可以提交 GitHub issue。
- 安全漏洞不要公开披露，请按照 [`SECURITY.md`](SECURITY.md) 报告。
- 不要提交真实订阅 URL、节点、UUID、密码、令牌、服务器地址、出口 IP 或个人配置。
- 大范围架构修改建议先开 issue 说明目标、平台范围和失败恢复方式。

## 本地验证

macOS 需要最新稳定版 macOS、Apple Silicon 和 Xcode Command Line Tools：

```bash
for test_script in Scripts/test-*.sh; do "$test_script" || exit; done
Scripts/build.sh
Scripts/package-macos.sh
```

Windows 需要 Windows 11、.NET 10 SDK、CMake、MSVC 和 WiX Toolset。Windows 逻辑测试、Guard、WPF 与 MSI 的完整构建命令以 [`.github/workflows/build.yml`](.github/workflows/build.yml) 为准。

修改 PF、WFP、Guard Service 或 MSI 卸载逻辑时，CI 构建不能替代真机安装、开启保护、紧急恢复、卸载和重装测试。pull request 中应明确列出实际完成的验证；未完成的项目也应如实说明。

## Pull request 清单

- 改动范围单一，提交信息能够解释用户可见结果。
- `git diff --check` 通过，仓库全部 `Scripts/test-*.sh` 通过。
- 修改实现时同步更新相关 README、测试和示例配置。
- 新增网络请求时说明目标、必要性、传输的数据以及默认是否启用。
- 新增依赖或第三方资产时记录来源、版本和许可证，并更新 `THIRD-PARTY-NOTICES.md`。
- 不在普通功能 pull request 中创建发布 tag、修改应用版本或提交构建产物。

## 设计边界

ProxyGauge 只观察和验证本机 Mihomo / Clash Verge 状态，不托管订阅、不保存节点，也不替用户配置服务器。安全相关代码必须保持 fail-closed 的卸载与恢复路径，不能为了让测试通过而绕过权限检查或降低保护边界。
