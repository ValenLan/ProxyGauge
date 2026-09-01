# ProxyGauge

<p align="center">
  <img src="Resources/ProxyGauge.png" width="144" alt="ProxyGauge icon">
</p>

ProxyGauge 是一个面向 macOS 与 Windows 11 的开源原生代理状态面板。它识别 Mihomo /
Clash Verge Rev 的本地入口和流量模式，验证 DNS、路由与实际出口，并提供可选的系统级
Kill Switch，防止代理失效后回退直连。

[下载最新版本](https://github.com/ValenLan/ProxyGauge/releases/latest) ·
[Windows 使用说明](Windows/README.md) ·
[参与贡献](CONTRIBUTING.md)

## 主要功能

- 自动识别 Mihomo 核心、mixed 端口、系统代理与 TUN 状态
- 使用三个独立来源交叉确认公网出口，并在 TUN 模式下验证 Fake-IP DNS
- 用可解释的 0–100 分展示核心、入口、DNS、出口与分流是否真实生效
- 支持可选的第二出口、策略组和域名规则检查
- 提供独立的 IP 纯净度复核入口，不把第三方风险分混入链路分
- 内置不含订阅或节点的 Clash Verge Rev / Mihomo Merge 规则包
- macOS 使用 SwiftUI 与 PF anchor；Windows 使用 WPF 与持久 WFP 规则
- 跟随系统浅色/深色外观，Windows 同时支持 High Contrast

## 支持平台

| 平台 | 链路检测 | Kill Switch | 发布包 |
|---|---:|---:|---|
| macOS 26（Apple Silicon） | ✓ | PF anchor（可选） | `ProxyGauge.app` |
| Windows 11 x64 | ✓ | 持久 WFP 规则 | self-contained MSI |
| Windows 11 ARM64 | ✓ | 持久 WFP 规则 | self-contained MSI |

Windows 10、Intel Mac 和旧版操作系统不在支持范围内。

## 安装

需要 Node.js 18 或更高版本时，可通过 npm 安装与包版本一致的 GitHub Release：

```bash
npm install -g proxygauge
```

也可以直接安装 GitHub 的 Latest Release：

Apple Silicon Mac：

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/ValenLan/ProxyGauge/main/Scripts/install-release-macos.sh)"
```

Windows 11 PowerShell（自动选择 x64 或 ARM64）：

```powershell
irm https://raw.githubusercontent.com/ValenLan/ProxyGauge/main/Scripts/install-release-windows.ps1 | iex
```

安装器会使用同一 Release 中的 `SHA256SUMS.txt` 校验安装包，不会下载源码构建，也不会安装
代理客户端、订阅或节点。运行远程脚本前应先检查内容并确认仓库所有者是 `ValenLan`。

当前 macOS 应用采用 ad-hoc 签名且尚未公证，Windows MSI 也未签名，因此 Gatekeeper 或
SmartScreen 可能显示提醒。安装器不会关闭或绕过系统安全检查。

## 使用

1. 启动已配置好的 Mihomo / Clash Verge Rev。
2. 打开 ProxyGauge，确认自动识别出的本地入口和流量模式。
3. 运行“链路检测”，查看核心、入口、DNS、出口和可选分流结果。
4. 需要防止代理失效后直连时，再明确开启 Kill Switch。

ProxyGauge 本身不是代理客户端，不提供订阅、节点或服务器，也不会替用户切换代理策略。

## 规则、隐私与安全边界

- Merge 规则包位于 [`Rules/ProxyGauge-Merge.yaml`](Rules/ProxyGauge-Merge.yaml)，默认策略组名为
  `PROXY`；导入前可按自己的订阅修改组名。
- 主界面的出口卡只经已配置的本地代理请求 `https://ipapi.co/json/`，读取并显示出口 IP 与
  城市/地区；不查询、推断或保存 IP 类型。该服务会像任何公网 IP 查询站点一样看到发起请求的出口 IP。
- 常规链路检测只通过本地代理访问公开 IP 查询与测试服务；默认不会请求 Claude、ChatGPT
  或 Gemini 的网页和 API。
- IP 纯净度复核只在用户确认后打开系统默认浏览器，各站结果不会被合并成伪精确总分。
- ProxyGauge 不读取网站 Cookie，不上传配置，不收集遥测，也不保存浏览记录。

Kill Switch 信任代理核心本身：它可以阻止普通应用在代理停止或入口失效后回退直连，但不能
阻止 Mihomo 自己执行 `DIRECT`。macOS 保护使用独立 PF anchor；Windows 保护由 LocalSystem
Guard Service 维护按用户限定的持久 WFP 规则。Windows 的启用、恢复和紧急关闭方法见
[`Windows/README.md`](Windows/README.md)，底层安全契约见
[`Windows.Guard/README.md`](Windows.Guard/README.md)。

## 从源码构建

macOS 需要 Apple Silicon、最新稳定版 macOS 与 Xcode Command Line Tools：

```bash
chmod +x Scripts/*.sh
Scripts/build.sh
Scripts/package-macos.sh
```

Windows 需要 Windows 11、.NET 10 SDK、CMake、MSVC 与 WiX Toolset。完整测试要求和提交清单
见 [`CONTRIBUTING.md`](CONTRIBUTING.md)，CI 构建流程见
[`.github/workflows/build.yml`](.github/workflows/build.yml)。

## 项目文档

- [Windows 使用与恢复说明](Windows/README.md)
- [Windows Guard 安全契约](Windows.Guard/README.md)
- [贡献指南](CONTRIBUTING.md)
- [安全报告方式](SECURITY.md)
- [第三方组件与许可](THIRD-PARTY-NOTICES.md)

## 许可证

ProxyGauge 采用 [`MIT License`](LICENSE) 开源。项目面向维护者当前使用的 macOS 与 Windows 11
环境；其他代理客户端、端口或网络接口可能需要额外配置。
