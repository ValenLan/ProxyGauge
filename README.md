# PuffRoute

<p align="center">
  <img src="Resources/PuffRoute.png" width="144" alt="PuffRoute icon">
</p>

PuffRoute 是一个轻量的原生代理状态面板，支持 macOS 与 Windows。它用来查看
Mihomo/Clash Verge 的核心、混合端口和流量入口状态，并提供结构化健康检查。

## 功能

- macOS 使用 SwiftUI，Windows 使用原生 WPF
- 检测 Mihomo 核心、mixed 端口、系统代理与 TUN 路由
- 用三个独立查询源交叉验证代理出口，识别出口漂移、分流或透明代理干扰
- TUN 生效时验证 DNS 是否返回 `198.18.x.x` Fake-IP，直接发现域名分流配置缺失
- 分开检查 ASN 归属、IP 段用途、风险标签、AI 站点真实响应和外网连通性
- 提供 BrowserLeaks、IPhey、IPQS、Scamalytics、AbuseIPDB 的浏览器深度复核入口
- 明确区分网络可达、IP 情报和登录账户状态；不会用网络检查结果推断账户未被封禁
- macOS 可选读取 Mihomo 运行时状态，独立验证 Google/Gemini 链式策略、规则命中、中性 204 延迟与真实链式出口 IP
- macOS 深度复核可分别用默认出口或 Google 链路启动临时 Chrome；不复用现有 Cookie、扩展或浏览器资料，也不修改系统代理
- 内置可独立分享的 Clash Verge Rev / Mihomo 规则包，不包含订阅或节点
- macOS 可选用独立 PF anchor 实现防泄漏 Kill Switch
- Windows 版只做只读网络检测，不修改全局防火墙策略
- macOS 健康检查、Kill Switch 脚本和管理员助手均内置于 App Bundle

## 平台支持

| 平台 | 状态面板 | 健康检查 | Kill Switch | 构建产物 |
|---|---:|---:|---:|---|
| macOS 13+ | ✓ | ✓ | PF anchor（可选） | `PuffRoute.app` |
| Windows 10/11 x64 | ✓ | ✓ | 暂不提供 | 单文件 `PuffRoute.exe` |
| Windows 11 ARM64 | ✓ | ✓ | 暂不提供 | 单文件 `PuffRoute.exe` |

## 规则包与订阅

PuffRoute 把两者有意分开：

- **订阅**由使用者自己的代理客户端管理，PuffRoute 不读取、不保存也不分发订阅地址、
  节点或凭据。
- **规则包**位于 [`Rules/PuffRoute-Merge.yaml`](Rules/PuffRoute-Merge.yaml)，随 macOS
  App 与 Windows 单文件程序一起打包，可从主界面底部“规则管理”入口预览、复制或导出。

规则包使用 Clash Verge Rev 的 `prepend-rules`，确保 AI 与开发站点规则排在订阅自带的
`GEOIP` / `MATCH` 规则之前，同时包含 TUN 所需的 Fake-IP DNS 配置。默认策略组名是
`PROXY`；如果朋友的订阅使用其他组名，导入前替换规则最后一列即可。导出后在 Clash
Verge Rev 中新建并启用 `Merge` 配置，再刷新当前订阅。这样规则可以共享，订阅仍由每个
人独立选择。

## macOS

### 系统要求

- macOS 13 或更高版本
- Xcode Command Line Tools
- 使用 Mihomo 核心的代理客户端（默认进程名 `verge-mihomo`）
- 默认 mixed 端口：`127.0.0.1:7890`

### 构建

```bash
chmod +x Scripts/*.sh
Scripts/build.sh
open build/PuffRoute.app
```

构建结果位于 `build/PuffRoute.app`，采用本机 ad-hoc 签名。

### 安装

```bash
Scripts/install.sh
```

默认安装到 `~/Applications/PuffRoute.app`，辅助脚本安装到：

- `~/.local/bin/puffroute-check`
- `~/.local/bin/puffroute-ip-risk.jxa`
- `~/.local/bin/puffroute-chain-check.jxa`
- `~/.local/bin/puffroute-private-browser`
- `~/.local/bin/puffroute-killswitch`
- `~/.local/share/puffroute/`

这些外部脚本用于命令行调用和旧版兼容；图形应用正常运行会优先使用 App Bundle
内置副本，因此单独移动 `PuffRoute.app` 不会丢失健康检查或管理员助手。

### 配置

安装脚本首次运行时会创建：

```text
~/.config/puffroute/config
```

主要配置项：

```bash
PUFFROUTE_MIXED="127.0.0.1:7890"
PUFFROUTE_EXPECT_IP=""  # 可选：校验准确的代理出口 IP
PUFFROUTE_GOOGLE_GROUP="Google-Chain"  # 可选：Google/Gemini 链式策略组
PUFFROUTE_GOOGLE_MIXED="127.0.0.1:7891"  # 可选：固定走 Google-Chain 的本地检测入口
PUFFROUTE_EXPECT_GOOGLE_IP=""  # 可选：校验准确的 Google/Gemini 出口 IP
PUFFROUTE_CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
PUFFROUTE_ACTIVE_AI_PROBES="0"  # 默认关闭：不主动请求任何 AI 平台
PUFFROUTE_VPS_IP=""     # 仅 PF Kill Switch 需要
```

仓库不包含任何真实服务器地址或个人配置。

如果 Google/Gemini 使用独立链式出口，仅检查策略组和规则命中还不够。把
[`Rules/PuffRoute-Google-Chain-Probe.yaml`](Rules/PuffRoute-Google-Chain-Probe.yaml)
中的 `listeners` 合并到 Mihomo 活动配置后，PuffRoute 会通过只监听
`127.0.0.1:7891` 的专用 mixed 入口查询实际出口，并在报告中并排显示默认出口与
Google/Gemini 出口。该入口固定绑定 `Google-Chain`，不会临时切换策略组，也不会暴露到
局域网。

### 可选：PF Kill Switch

> PF 配置会影响整台 Mac 的联网行为。请先阅读脚本和规则，并确保你有可恢复的
> 本地终端访问。配置错误可能导致暂时断网。

填写 `PUFFROUTE_VPS_IP` 后运行：

```bash
Scripts/install-pf.sh
```

该脚本会：

1. 生成 `/etc/pf.anchors/puffroute`
2. 在当前 `/etc/pf.conf` 中注册 `anchor "puffroute"`
3. 先运行 PF 语法检查，再安装配置
4. 首次执行时备份 `/etc/pf.conf.puffroute.bak`

安装规则后，可在 PuffRoute 界面中开启或关闭 Kill Switch。

从旧版 Proxy Tools 升级时，如果系统仍注册旧的 `killswitch` anchor，PuffRoute 会
继续调用原有规则，避免仅因应用改名而失去保护。全新安装始终使用 `puffroute`
anchor。

## Windows

Windows 版位于 [`Windows/`](Windows/)，使用 .NET 8 WPF，不依赖第三方 UI 框架。

### 使用预编译版本

1. 在 GitHub Actions 的最新成功构建中下载 `PuffRoute-win-x64`；ARM Windows
   下载 `PuffRoute-win-arm64`
2. 解压后运行 `PuffRoute.exe`
3. 点击标题栏的设置按钮，确认 mixed 地址与端口

发布包为 self-contained 单文件程序，朋友的电脑无需预装 .NET。Windows 首次运行
未经代码签名的个人应用时，SmartScreen 可能显示提醒。

### 本地构建

需要 .NET 8 SDK 与 Windows 10/11：

```powershell
dotnet publish Windows/PuffRoute.Windows.csproj `
  --configuration Release `
  --runtime win-x64 `
  --self-contained true `
  -p:PublishSingleFile=true
```

Windows 配置保存在：

```text
%APPDATA%\PuffRoute\config.json
```

Windows 版没有照搬 macOS Kill Switch。可靠的 Windows 等价方案需要修改全局
Firewall/WFP 策略，误配置可能让整台电脑断网；当前分享版刻意保持只读。

## 隐私与安全

- 健康检查会通过已配置的本地代理访问公开 IP 查询服务和测试站点。
- 默认健康检查不会请求 Claude、ChatGPT、Gemini 的网页或 API。Google/Gemini 的路由
  命中从本机 Mihomo 运行时读取，链路延迟使用中性 204 地址，实际出口通过专用本地入口
  访问公开 IP 查询服务确认。只有用户显式把 `PUFFROUTE_ACTIVE_AI_PROBES` 设为 `1` 时，
  macOS 才会主动请求三个 AI API；即使启用，也不会自动访问账号网页。
- 出口一致性检查会把默认代理出口分别提交给 `api.ipify.org`、`ifconfig.me` 与 `ip.sb`；
  启用链式出口探针时，也会经固定的 Google/Gemini 链路访问同一组服务。只有至少两个
  来源给出一致结果才算完成交叉验证。
- IP 风险画像会把实测出口 IP 提交给 `ipapi.is` 与 `proxycheck.io`，并把查询得到的 ASN
  提交给 `PeeringDB`。启用 Google/Gemini 链式探针后，默认出口与链式出口会分别查询、
  分开展示，避免拿默认 IP 的结论评价 Google 链路。报告会分别展示网络归属、ASN 属性、
  IP 段用途、风险分与地址风险标签，避免把运营商类型和具体地址用途混为一谈。第三方情报
  仅供参考，接口限流不会被视为代理故障。
- IPQS、Scamalytics、AbuseIPDB、BrowserLeaks 与 IPhey 只作为用户主动点击的复核入口，
  PuffRoute 不会在后台自动访问。BrowserLeaks/IPhey 必须在真实浏览器上下文中运行，才能
  观察 WebRTC、DNS、IPv6、时区和指纹一致性。
- PuffRoute 不读取 Claude、ChatGPT 等网站的登录 Cookie 或账户资料，因此无法自动判断
账户封禁。健康报告会把账户状态显示为“未验证”，必须在用户自己的真实登录会话中确认。
- macOS 的“隔离浏览器检测”只在用户点击后启动独立 Chrome 进程。它使用临时资料目录、
  禁用现有扩展与同步，并通过进程专属的本机代理打开 BrowserLeaks、IPhey、IPQS、
  Scamalytics 与 AbuseIPDB；关闭该 Chrome 窗口后删除临时资料。检测网站仍能看到所选
  出口 IP 和浏览器指纹，因此“隔离”不等于对网站匿名。该功能不会改变系统代理，也不会
  影响普通 Chrome 窗口和其他应用的流量。
- PuffRoute 不上传配置，不收集遥测，也不保存浏览记录。
- macOS 管理员权限仅用于读取或修改 PuffRoute 自己的 PF anchor。
- Windows 版不请求管理员权限，也不修改 Windows Firewall。
- 发布前请不要提交 `~/.config/puffroute/config`。

## 项目状态

这是一个面向个人 macOS 代理环境的小工具。不同代理客户端、端口和 PF 网络接口
可能需要调整配置。欢迎通过 Issue 报告可复现的问题。
