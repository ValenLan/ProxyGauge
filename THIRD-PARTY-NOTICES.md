# Third-party notices

ProxyGauge 源码仓库不内嵌第三方应用框架，但构建与 Windows self-contained 安装包会使用以下组件。此文件是组件清单，不替代各组件随附的许可证文本。

## .NET 10

Windows WPF 应用以 self-contained 方式发布并包含 .NET runtime 与 Windows Desktop 组件。.NET 源码采用 MIT License；Windows 产品分发还受 Microsoft 的 .NET Library License 和相应第三方声明约束。

Windows CI 会从实际执行构建的 .NET SDK 目录复制 `LICENSE.txt` 和 `ThirdPartyNotices.txt`，并以 `DOTNET-LICENSE.txt`、`DOTNET-THIRD-PARTY-NOTICES.txt` 随 MSI 安装。

- Source and license information: <https://github.com/dotnet/core/blob/main/license-information.md>
- Runtime source: <https://github.com/dotnet/runtime>

## WiX Toolset 6.0.2

Windows MSI 使用 WiX Toolset SDK 6.0.2 与 `WixToolset.Util.wixext` 6.0.2 构建。WiX Toolset 源码采用 Microsoft Reciprocal License (MS-RL)。完整许可文本保存在 [`ThirdParty/WiX-6.0.2-LICENSE.txt`](ThirdParty/WiX-6.0.2-LICENSE.txt)，并随 MSI 安装。

WiX 提供的预编译工具还受其 Open Source Maintenance Fee Agreement 约束；非营收使用免维护费，营收使用者应自行核对当前条款。

- WiX 6.0.2 source and license: <https://github.com/wixtoolset/wix/tree/v6.0.2>
- Maintenance fee agreement: <https://github.com/wixtoolset/wix/blob/v6.0.2/OSMFEULA.txt>

## GitHub Actions

CI 使用 GitHub 官方的 `checkout`、`setup-dotnet`、`upload-artifact` 和 `download-artifact` actions。这些 action 只在 GitHub 托管 runner 中执行，不打包进 ProxyGauge 安装产物。

## 系统框架

macOS 版本使用系统提供的 AppKit、SwiftUI、Darwin 与 UniformTypeIdentifiers；Windows Guard 使用 Windows SDK 和 Windows Filtering Platform。它们不作为第三方源码复制到本仓库。
