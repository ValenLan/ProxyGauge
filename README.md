# PuffRoute

<p align="center">
  <img src="Resources/PuffRoute.png" width="144" alt="PuffRoute icon">
</p>

PuffRoute 是一个轻量的原生代理状态面板，支持 macOS 与 Windows。它用来查看
Mihomo/Clash Verge 的核心、混合端口和流量入口状态，并提供结构化健康检查。

## 功能

- macOS 使用 SwiftUI，Windows 使用原生 WPF
- 检测 Mihomo 核心、mixed 端口、系统代理与 TUN 路由
- 检查代理出口 IP、常用 AI 站点和外网连通性
- macOS 可选用独立 PF anchor 实现防泄漏 Kill Switch
- Windows 版只做只读网络检测，不修改全局防火墙策略
- macOS 健康检查、Kill Switch 脚本和管理员助手均内置于 App Bundle

## 平台支持

| 平台 | 状态面板 | 健康检查 | Kill Switch | 构建产物 |
|---|---:|---:|---:|---|
| macOS 13+ | ✓ | ✓ | PF anchor（可选） | `PuffRoute.app` |
| Windows 10/11 x64 | ✓ | ✓ | 暂不提供 | 单文件 `PuffRoute.exe` |
| Windows 11 ARM64 | ✓ | ✓ | 暂不提供 | 单文件 `PuffRoute.exe` |

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
PUFFROUTE_VPS_IP=""     # 仅 PF Kill Switch 需要
```

仓库不包含任何真实服务器地址或个人配置。

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
- PuffRoute 不上传配置，不收集遥测，也不保存浏览记录。
- macOS 管理员权限仅用于读取或修改 PuffRoute 自己的 PF anchor。
- Windows 版不请求管理员权限，也不修改 Windows Firewall。
- 发布前请不要提交 `~/.config/puffroute/config`。

## 项目状态

这是一个面向个人 macOS 代理环境的小工具。不同代理客户端、端口和 PF 网络接口
可能需要调整配置。欢迎通过 Issue 报告可复现的问题。
