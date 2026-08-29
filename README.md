# ProxyGauge

<p align="center">
  <strong>简体中文</strong> · <a href="README.en.md">English</a>
</p>

<p align="center">
  <img src="Resources/ProxyGauge.png" width="144" alt="ProxyGauge icon">
</p>

ProxyGauge 是一个面向最新稳定版 macOS 与 Windows 11 的开源原生代理状态、链路验证与
防泄漏面板。它可以识别 Mihomo / Clash Verge Rev 的核心、mixed 入口、系统代理与 TUN
状态，交叉验证实际代理出口，并通过可选的 macOS PF 或 Windows WFP Kill Switch 防止代理
失效后回退直连。项目不包含代理订阅或节点，也不收集遥测。

## 功能

- macOS 使用 SwiftUI，Windows 使用原生 WPF
- macOS 与 Windows 均跟随系统浅色/深色外观；Windows 还会优先遵循 High Contrast
- 应用图标由同一 1024 px `ProxyGauge-source.png` 母版生成 macOS `icns`、Windows 多尺寸 `ico` 与 WPF 高清 `png`
- 检测 Mihomo 核心、mixed 端口、系统代理与 TUN 路由
- macOS 与 Windows 首次启动均自动识别 Clash Verge Rev / Mihomo 的本地入口与流量模式；检测失败才要求手动填写端口
- 流量入口卡片按实际状态切换：仅系统代理或仅 TUN 显示绿色，两者同时开启显示橙色提示，两者均未开启显示灰色
- 用三个独立查询源交叉验证代理出口，识别出口漂移、分流或透明代理干扰
- TUN 生效时验证 DNS 是否返回 `198.18.x.x` Fake-IP，直接发现域名分流配置缺失
- 常规链路检测只回答核心、入口、DNS、出口与分流是否真实生效，不再把第三方 IP 风险分混入链路分
- macOS 与 Windows 均提供独立“IP 纯净度”入口；确认后先经当前本地代理读取出口 IP，再打开 4 个自动识别页和 2 个带 IP 的结果页
- 多站结果保留各自定义，不合并成伪精确总分；人工复核与账户判断不计入通过、提示或失败
- 链路检测运行时显示线性进度，完成后给出可解释的 0–100 链路分
- 两端默认使用不假定代理拓扑的通用方案；额外出口、策略组和域名规则由用户按需启用
- 现有 Google/Gemini/Claude 链式出口结构保留为预填模板，可修改名称、策略组、本地入口和目标域名
- 两端深度复核均使用系统默认浏览器和当前真实浏览器网络路径；ProxyGauge 不强制浏览器使用特定节点，也不修改系统代理
- 内置可独立分享的 Clash Verge Rev / Mihomo 规则包，不包含订阅或节点
- macOS 可选用独立 PF anchor 实现防泄漏 Kill Switch
- Windows 版由独立 LocalSystem 服务维护按用户限定的持久 WFP 防泄漏规则
- macOS 链路检测、Kill Switch 脚本和管理员助手均内置于 App Bundle

## 平台支持

| 平台 | 状态面板 | 链路检测 | Kill Switch | 构建产物 |
|---|---:|---:|---:|---|
| macOS 26（Apple Silicon） | ✓ | ✓ | PF anchor（可选） | `ProxyGauge.app` |
| Windows 11 x64 | ✓ | ✓ | 持久 WFP 规则 | self-contained MSI |
| Windows 11 ARM64 | ✓ | ✓ | 持久 WFP 规则 | self-contained MSI |

支持所有正式发布的 Windows 11；Windows 10 会被明确拒绝启动，也不为其增加兼容分支。

## 一行安装正式版

开发者可通过 npm 全局安装。需要预先安装 Node.js 18 或更高版本；npm 包会自动识别平台与
架构，安装和 npm 包版本一致的 GitHub 正式版，并根据同一 Release 中的
`SHA256SUMS.txt` 校验安装包：

```bash
npm install -g proxygauge
```

如果 npm 被配置为不运行生命周期脚本，完成全局安装后可显式运行 `proxygauge install`。
不使用 npm 时，也可以直接运行下面的平台安装入口。它们会安装 GitHub 的 **Latest Release**，
不会下载源码构建，也不会安装代理客户端、订阅或节点。

Apple Silicon Mac：

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/ValenLan/ProxyGauge/main/Scripts/install-release-macos.sh)"
```

Windows 11（在 PowerShell 中运行，自动选择 x64 或 ARM64，安装 MSI 时会请求管理员权限）：

```powershell
irm https://raw.githubusercontent.com/ValenLan/ProxyGauge/main/Scripts/install-release-windows.ps1 | iex
```

这些入口会执行 npm 包或本仓库中的安装脚本。谨慎的做法是先阅读 npm 包内容或在浏览器打开
命令里的 URL 阅读脚本，确认仓库所有者是 `ValenLan`，再运行。当前正式版尚未购买平台代码签名证书：macOS 使用
ad-hoc 签名且尚未公证，Windows MSI 也未签名，因此系统可能显示安全提醒；安装器会保留
Gatekeeper、SmartScreen 和管理员授权检查，不会替用户关闭或绕过这些保护。

## 规则包与订阅

ProxyGauge 把两者有意分开：

- **订阅**由使用者自己的代理客户端管理，ProxyGauge 不读取、不保存也不分发订阅地址、
  节点或凭据。
- **规则包**位于 [`Rules/ProxyGauge-Merge.yaml`](Rules/ProxyGauge-Merge.yaml)，随 macOS
  App 与 Windows MSI 一起打包，可从主界面底部“规则管理”入口预览、复制或导出。

规则包使用 Clash Verge Rev 的 `prepend-rules`，确保 AI 与开发站点规则排在订阅自带的
`GEOIP` / `MATCH` 规则之前，同时包含 TUN 所需的 Fake-IP DNS 配置。默认策略组名是
`PROXY`；如果朋友的订阅使用其他组名，导入前替换规则最后一列即可。导出后在 Clash
Verge Rev 中新建并启用 `Merge` 配置，再刷新当前订阅。这样规则可以共享，订阅仍由每个
人独立选择。

## macOS

### 系统要求

- 最新版 macOS 26，Apple Silicon Mac
- 使用 Mihomo 核心的代理客户端（默认进程名 `verge-mihomo`）
- 默认 mixed 端口：`127.0.0.1:7890`

### 构建

构建需要 Xcode Command Line Tools；仅运行预编译版本不需要。

```bash
chmod +x Scripts/*.sh
Scripts/build.sh
Scripts/package-macos.sh
open "build/ProxyGauge.app"
```

仅在修改图标母版后运行 `Scripts/generate-icons.mjs`（需要 Node.js）；它会重建两端全部尺寸的图标资源。

构建结果位于 `build/ProxyGauge.app`，分享包位于
`dist/ProxyGauge-<版本>-macOS-arm64.zip`。应用采用 ad-hoc 签名，尚未使用 Developer ID
签名或 Apple 公证。

### 分享预编译版本

推荐从 GitHub Releases 分享一个 macOS ZIP 和两个 Windows MSI，而不是分享源码、App 目录或
`Scripts/` 目录：

- `ProxyGauge-<版本>-macOS-arm64.zip`
- `ProxyGauge-<版本>-win-x64.msi`
- `ProxyGauge-<版本>-win-arm64.msi`

用户可从 GitHub Releases 下载对应安装包与 `SHA256SUMS.txt`，并在运行前核对校验值。

Mac 用户解压后把 `ProxyGauge.app` 移到“应用程序”即可；正常图形功能所需的检查脚本、规则
和管理员助手已包含在 App 内，不需要运行 `install.sh`。由于当前版本没有 Apple 公证，首次
打开可能被 Gatekeeper 拦截；只应在确认下载来源与 `SHA256SUMS.txt` 校验值后，到“系统
设置 → 隐私与安全性”选择“仍要打开”。面向更广泛用户公开分发前，应补齐 Developer ID
签名与公证。

macOS 首次启动会优先从 Mihomo 本地控制 socket、macOS 系统代理和 Clash Verge Rev 根设置
文件中识别当前 mixed 端口，并展示“代理客户端 → 本地入口 → 流量模式”供用户一次确认。
自动检测只提取端口与运行模式，不读取或保存订阅 URL、节点、UUID、密码或密钥；检测失败
时才显示只允许本机回环地址的手动端口输入。确认结果保存在 ProxyGauge 自己的 macOS 偏好
中，标题栏的连接设置按钮可以随时重新检测。

分享包不包含代理客户端、订阅、节点、服务器地址或个人配置。朋友仍需自行安装并配置
Mihomo/Clash Verge；PF Kill Switch 的脚本和默认规则随 App 提供，但只有用户主动打开开关并
确认管理员授权后才会安装和启用。

### 安装

```bash
Scripts/install.sh
```

默认安装到 `~/Applications/ProxyGauge.app`，辅助脚本安装到：

- `~/.local/bin/proxygauge-check`
- `~/.local/bin/proxygauge-ip-risk.jxa`
- `~/.local/bin/proxygauge-chain-check.jxa`
- `~/.local/bin/proxygauge-killswitch`
- `~/.local/share/proxygauge/`

这些外部脚本用于命令行调用和旧版兼容；图形应用正常运行会优先使用 App Bundle
内置副本，因此单独移动 `ProxyGauge.app` 不会丢失链路检测或管理员助手。

### 配置

普通 macOS 图形用户不需要创建配置文件；首次引导确认的本地入口会直接传给 App 内置脚本。
下面的文件仅用于开发者命令行和高级链式出口；运行安装脚本时会创建：

```text
~/.config/proxygauge/config
```

主要配置项：

```bash
PROXYGAUGE_MIXED="127.0.0.1:7890"
PROXYGAUGE_EXPECT_IP=""  # 可选：校验准确的代理出口 IP
PROXYGAUGE_SECONDARY_ENABLED="0"  # 普通单出口保持关闭
PROXYGAUGE_SECONDARY_LABEL="Google / Gemini / Claude"  # 预填模板，可改名
PROXYGAUGE_SECONDARY_GROUP="Google-Chain"
PROXYGAUGE_DEFAULT_GROUP="PROXY"
PROXYGAUGE_SECONDARY_MIXED="127.0.0.1:7891"
PROXYGAUGE_SECONDARY_DOMAINS="gemini.google.com,generativelanguage.googleapis.com,www.google.com,claude.ai,api.anthropic.com,platform.claude.com,bridge.claudeusercontent.com"
PROXYGAUGE_EXPECT_SECONDARY_IP=""  # 可选：校验额外出口基线
PROXYGAUGE_ACTIVE_AI_PROBES="0"  # 默认关闭：不主动请求任何 AI 平台
```

安装与运行只使用 `com.valenlan.proxygauge`、`ProxyGauge`、`proxygauge` 和
`PROXYGAUGE_*` 标识，不维护旧产品名、旧配置路径或旧环境变量兼容。

仓库不包含任何真实服务器地址或个人配置。

如果启用了独立链式出口，仅检查策略组和规则命中还不够。当前预填模板使用
[`Rules/ProxyGauge-Google-Chain-Probe.yaml`](Rules/ProxyGauge-Google-Chain-Probe.yaml)
中的 `listeners` 合并到 Mihomo 活动配置后，ProxyGauge 会通过只监听
`127.0.0.1:7891` 的专用 mixed 入口查询实际出口，并在报告中并排显示默认出口与
额外出口。该示例入口固定绑定 `Google-Chain`，不会临时切换策略组，也不会暴露到局域网；
其他用户可以在“链路检测 → 方案”中替换成自己的策略组、端口和域名。

### 可选：PF Kill Switch

首页 Kill Switch 是持久的“开启 / 关闭”开关，不收集服务器 IP、网卡或其他规则参数。
全新 Mac 第一次开启时，ProxyGauge 使用 App 内置模板自动识别物理接口，并确认 Mihomo 核心
由系统服务运行；随后在一次管理员授权中校验 anchor 与临时主配置、备份 `/etc/pf.conf`、
安装规则并立即开启。任一步失败都会保持关闭并回滚本次安装。

应用启动和普通状态刷新不会请求管理员权限，也不会修改 PF。

用户开启 Kill Switch 后，helper 会把一份 root-owned 恢复程序安装到
`/Library/PrivilegedHelperTools/com.valenlan.proxygauge.killswitch`，并注册
`/Library/LaunchDaemons/com.valenlan.proxygauge.killswitch.plist`。开启意图以 root-only 标记
保存在 `/var/db/proxygauge/enabled`；LaunchDaemon 在启动时以及运行中每 15 秒校验已有 anchor、
物理接口和 PF enable reference。用户主动关闭时会同时清除该标记，因此开启和关闭状态都会
跨应用退出与系统重启保持。界面读取 `/var/run/proxygauge-killswitch.state` 的 root-owned 运行
状态，并同时核对当前启动周期的 PF reference，不沿用重启前的绿色缓存。

PF 会影响整台 Mac 的联网行为，因此自动安装只允许 root 身份运行的代理核心和其他 root
系统服务经物理接口联网；普通应用必须走本机代理或 TUN，用户进程也没有独立的 53 端口直连
例外。显式开启时还会清理物理接口已有的 PF 连接状态，使旧连接重新经过新规则。命令行用户
也可以运行同一套无参数安装流程：

```bash
Scripts/install-pf.sh
```

该脚本会：

1. 生成 `/etc/pf.anchors/proxygauge`
2. 在当前 `/etc/pf.conf` 中注册 `anchor "proxygauge"`
3. 先检查 anchor 与系统 PF 配置语法，再安装配置
4. 首次执行时备份 `/etc/pf.conf.proxygauge.bak`

命令行安装会自动识别接口，只写入内置规则并保持关闭；完成后由 ProxyGauge 开关启用。

Kill Switch 仅支持 `proxygauge` anchor。已有其他 anchor 的系统需要先单独完成清理和
迁移；ProxyGauge 不会自动叠加第二套 PF 规则。

当前 Kill Switch 的信任边界是代理核心本身：macOS PF 需要允许 root-owned Mihomo 与系统服务
出站，Windows WFP 需要允许 mixed 端口对应的 Mihomo 可执行文件。因此它能阻止普通应用在代理
停止或入口失效后回退直连，但不能阻止代理核心自身执行 `DIRECT`。ProxyGauge 不读取订阅和节点，
Mihomo 的本地状态接口也不能稳定给出所有活动传输的最终物理端点；项目不会猜测节点 IP 并建立
可能导致永久断网的出口白名单。只有未来能原子获得并验证完整端点集合时，才会加入这种严格模式。

## Windows

Windows 版位于 [`Windows/`](Windows/)，使用 .NET 10 WPF，不依赖第三方 UI 框架。

### 使用预编译版本

1. 在 GitHub Releases 下载 `ProxyGauge-<版本>-win-x64.msi`；ARM Windows 下载
   `ProxyGauge-<版本>-win-arm64.msi`，并使用 `SHA256SUMS.txt` 核对文件
2. 运行 MSI；安装时授权一次管理员权限，用于安装自动启动的 Guard Service
3. 从开始菜单运行 ProxyGauge，确认 mixed 地址与端口，再明确开启“系统保护”

MSI 内的界面和系统服务都是 self-contained，朋友的电脑无需预装 .NET。Windows 首次运行
未经代码签名的个人应用时，SmartScreen 可能显示提醒。

### 本地构建

需要 .NET 10 SDK、CMake、MSVC 和 Windows 11：

```powershell
dotnet publish Windows/ProxyGauge.Windows.csproj `
  --configuration Release `
  --runtime win-x64 `
  --self-contained true
```

Windows 配置保存在：

```text
%APPDATA%\ProxyGauge\config.json
```

Windows Guard 使用系统自带 Windows Filtering Platform，不安装内核驱动。保护开启时，
服务只给当前启用用户建立规则：允许回环代理、实际监听 mixed 端口的代理核心和已识别的
TUN 接口，拦截其余 IPv4/IPv6 直连。规则属于 WFP 持久对象，不依赖 WPF 界面进程：关闭
窗口、退出界面、用户注销或界面崩溃都不会解除拦截；重启后由自动启动服务校验和修复。

只有主界面的明确“关闭”操作或管理员紧急恢复命令会永久解除保护。若界面不可用，在管理员
终端运行：

```powershell
& "C:\Program Files\ProxyGauge\ProxyGauge.Guard.exe" --emergency-off
```

如果该文件也损坏，管理员可执行 `sc.exe config ProxyGaugeGuard start= disabled` 后重启；
BFE 在启动时不会装载属于已禁用服务的持久 provider 规则。这是最后恢复手段，不是日常开关。

卸载程序会先停止服务并执行同样的清理；若无法完整移除持久规则，卸载会失败而不是遗留
一个无法恢复的半卸载状态。

## 发布

每次 push 与 pull request 都会构建并测试 macOS、Windows x64 和 Windows ARM64。只有推送与
应用版本完全一致的 `v<版本>` 标签时，工作流才会把一个 macOS ZIP 和两个 Windows MSI 暂存
为 Actions artifacts，创建 GitHub Release，并上传这些安装包与 `SHA256SUMS.txt`。临时 artifacts
只保留 1 天；正式安装包由 Release 长期保存。例如当前版本对应的发布标签应为 `v1.5.7`。

创建标签会产生正式发布结果，必须在全部本地测试和普通 push CI 通过后由维护者明确执行；
构建脚本本身不会自动创建标签。

这里的 GitHub Release 指正式版的发布页和安装包，不是测试版。工作流不会创建草稿或
Pre-release，并会把新版本标记为 Latest；只有 Latest 正式版才会被上面的一行安装器选中。

## 参与贡献与安全报告

- 开发环境、测试要求和 pull request 清单见 [`CONTRIBUTING.md`](CONTRIBUTING.md)。
- 安全问题请按 [`SECURITY.md`](SECURITY.md) 私下报告，不要在公开 issue 中附带漏洞细节、
  真实订阅、节点、出口 IP 或个人配置。
- 构建和发布涉及的第三方组件及随安装包分发的许可文件见
  [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md)。

## 许可证

ProxyGauge 采用 [`MIT License`](LICENSE) 开源。MIT 许可证允许他人使用、复制、修改、合并、
发布和分发，但要求在副本或主要部分中保留版权与许可声明；软件按原样提供，不附带任何保证。
许可证本身不能替代对代码、图标、文案和第三方依赖授权来源的确认。

## 隐私与安全

- 链路检测会通过已配置的本地代理访问公开 IP 查询服务和测试站点。
- 默认链路检测不会请求 Claude、ChatGPT、Gemini 的网页或 API。启用额外分流模板后，规则
  命中从本机 Mihomo 运行时读取，链路延迟使用中性 204 地址，实际出口通过专用本地入口
  访问公开 IP 查询服务确认。只有用户显式把 `PROXYGAUGE_ACTIVE_AI_PROBES` 设为 `1` 时，
  macOS 才会主动请求三个 AI API；即使启用，也不会自动访问账号网页。
- 出口一致性检查会把默认代理出口分别提交给 `api.ipify.org`、`ifconfig.me` 与 `ip.sb`；
  启用额外出口探针时，也会经该用户设置的本地入口访问同一组服务。只有至少两个
  来源给出一致结果才算完成交叉验证。
- 常规链路检测不再把出口 IP 提交给风险情报服务，也不生成“纯净度”结论；它只通过
  `api.ipify.org`、`ifconfig.me` 与 `ip.sb` 交叉确认实际出口。
- IPPure、IPCheck.ing、BrowserLeaks、IPQS、Scamalytics 与 AbuseIPDB 只作为用户主动点击并再次确认的
  复核入口，ProxyGauge 不会在后台自动访问。确认框会明确说明即将弹出系统默认浏览器；部分网站
  可能要求完成人机验证。它们必须在真实浏览器上下文中运行，才能同时
  观察当前出口、WebRTC、DNS、IPv6、时区和指纹一致性。各站使用的数据库、风险定义与更新
  周期不同，结果应交叉阅读，不能视为目标平台的官方判定。
- 用户确认后，ProxyGauge 会先经已确认的本地 mixed 入口查询当前出口 IP，仅用于生成
  `scamalytics.com/ip/<IP>` 与 `abuseipdb.com/check/<IP>` 两个直达结果链接；查询失败时不打开
  这两个需要参数的入口，避免落到要求再次输入 IP 的首页。其余 4 个站点由网页识别当前访问 IP。
- ProxyGauge 不读取 Claude、ChatGPT 等网站的登录 Cookie 或账户资料，也不会把账户判断
  塞进常规链路报告。账户状态只能由用户在自己的正常登录会话中确认。
- 链路分只汇总当前检测方案：通用方案按核心、端口、入口与出口四段归一化；启用额外分流后
  才加入策略、规则与第二出口权重。提示扣对应部分一半权重，失败扣全部权重；关键入口失败时
  最高为 49 分。它不是网速、纯净度、匿名性或账户安全评分。
- macOS 的“IP 纯净度复核”先询问用户，确认后读取当前代理出口并通过系统默认浏览器打开 6 个站点。它沿用用户
  当前浏览器会话与实际网络路径，不创建临时资料目录、不指定进程专属代理，也不改动系统代理。
  用户需要自行完成人机验证并交叉阅读各站结果；ProxyGauge 不自动抓取、汇总或计分。
- ProxyGauge 不上传配置，不收集遥测，也不保存浏览记录。
- macOS 管理员权限仅用于读取或修改 ProxyGauge 自己的 PF anchor，以及安装和维护上述
  root-owned 开机恢复 helper、LaunchDaemon 与启用标记。
- Windows 日常界面不请求管理员权限；MSI 只在安装/卸载 LocalSystem Guard Service 时请求。
  Guard 直接管理 ProxyGauge 自己的 WFP provider/sublayer，不修改 Windows Firewall 的默认策略。
- 发布前请不要提交 `~/.config/proxygauge/config`。

## 项目状态

这是一个面向个人最新 macOS 与 Windows 11 环境的小工具。不同代理客户端、端口和 PF
网络接口可能需要调整配置。旧版操作系统不在测试和维护范围内。
