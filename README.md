# ProxyGauge

<p align="center">
  <img src="Resources/ProxyGauge.png" width="144" alt="ProxyGauge icon">
</p>

ProxyGauge 是一个面向 macOS 与 Windows 11 的开源原生代理状态面板。它识别 Mihomo /
Clash Verge Rev 的本地入口和流量模式，显示系统实际出口，并提供可选的系统级
Kill Switch，防止代理失效后回退直连。

[下载最新版本](https://github.com/ValenLan/ProxyGauge/releases/latest) ·
[Windows 使用说明](Windows/README.md) ·
[参与贡献](CONTRIBUTING.md)

## 主要功能

- 自动识别 Mihomo 核心、mixed 端口、系统代理与 TUN 状态
- 沿系统当前网络路径显示公网出口、国家/地区/城市及 IPv4/IPv6
- 主查询必须经独立来源确认；发生冲突时以严格多数交叉确认出口
- 仅在网络路由、系统代理或 VPN/TUN 路径变化时清除旧结果并重新核验
- 提供需要用户确认的 IP 纯净度、隐私泄露与浏览器测速入口
- 内置不含订阅或节点的 Clash Verge Rev / Mihomo Merge 规则包
- macOS 使用 SwiftUI 与 PF anchor；Windows 使用 WPF 与持久 WFP 规则
- 支持手动切换浅色/深色外观，Windows 同时支持 High Contrast

## 支持平台

| 平台 | 原生状态面板 | Kill Switch | 发布包 |
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

为避免 npm 环境变量把提权进程引向伪造的系统程序，Windows npm 自动安装会固定使用受保护的
`C:\Windows\System32`，因此只支持默认 Windows 系统目录。Windows 安装在其他系统盘时，请
改用下方独立 PowerShell 安装器；该安装器从 Windows API 读取实际系统目录。

也可以直接安装 GitHub 的 Latest Release：

Apple Silicon Mac：

```bash
/bin/bash -p -c "$(curl -fsSL https://raw.githubusercontent.com/ValenLan/ProxyGauge/main/Scripts/install-release-macos.sh)"
```

Windows 11 PowerShell（自动选择 x64 或 ARM64）：

```powershell
irm https://raw.githubusercontent.com/ValenLan/ProxyGauge/main/Scripts/install-release-windows.ps1 | iex
```

安装器会使用同一 Release 中的 `SHA256SUMS.txt` 校验安装包，不会下载源码构建，也不会安装
代理客户端、订阅或节点。运行远程脚本前应先检查内容并确认仓库所有者是 `ValenLan`。
macOS 正式安装会把应用本体放到受 root 保护的
`/Applications/ProxyGauge.app` 的真实应用包；旧的受保护目录安装会在升级时迁移并清理，因此 Finder 不再显示替身箭头；
这是 Kill Switch 管理员操作校验应用与内置组件完整性的安全边界。
macOS 重新安装前请先退出 ProxyGauge；安装器会在下载和替换前检查旧实例，发现仍在运行时停止并提示重试。

当前 macOS 应用采用 ad-hoc 签名且尚未公证，Windows MSI 也未签名，因此 Gatekeeper 或
SmartScreen 可能显示提醒。安装器不会关闭或绕过系统安全检查。

## 使用

1. 按需启动 Mihomo / Clash Verge Rev 或其他 VPN；没有代理时也可读取系统直连出口。
2. 打开 ProxyGauge，确认自动识别出的系统代理、VPN / TUN 或直连路径；Mihomo 专项检测才需要对应本地入口。
3. 查看“代理状态”和“系统实际出口”；没有有效缓存时先核验一次出口 IP，之后在系统路径变化时更新。手动刷新只更新本机代理状态。
4. 需要防止代理失效后直连时，再明确开启 Kill Switch。

ProxyGauge 本身不是代理客户端，不提供订阅、节点或服务器，也不会替用户切换代理策略。

## 规则、隐私与安全边界

- Merge 规则包位于 [`Rules/ProxyGauge-Merge.yaml`](Rules/ProxyGauge-Merge.yaml)，默认策略组名为
  `PROXY`；导入前可按自己的订阅修改组名。
- macOS 与 Windows 主界面的“系统实际出口”卡遵循当前系统代理、PAC、VPN、TUN 或直连
  路径。应用先从 `ipapi.co` 读取出口 IP 与国家/地区/城市，并用 `api.ipify.org` 独立确认；
  两者冲突、信息不完整或请求失败时，再按需查询 `ipwho.is`、`ifconfig.me` 与 `ip.sb`；只有在
  已获得响应的独立来源中超过半数、且至少有两票确认同一地址时才显示结果。整次核验最多 15 秒。
  国家缺失时不会把城市单独冒充完整地区。IPv4/IPv6 标签仅
  根据严格验证后的公网地址在本机解析。应用不查询、推断或保存住宅、机房、代理等网络类型，
  无代理时，这些 HTTPS 查询会让所用服务看到真实公网 IP 和请求时间，
  但不会发送本机代理端口、订阅、节点、凭据或检测历史。应用会在本机缓存上一次已确认的 IP、
  位置及路径指纹；启动时没有完整有效缓存会检测一次。已有缓存且路径未变时，打开页面、
  切回应用和手动刷新不会重复查询；网络路由、系统代理或 VPN/TUN 路径变化后才重新检测。
- 主界面不会在后台请求 Claude、ChatGPT 或 Gemini 的网页和 API。
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
