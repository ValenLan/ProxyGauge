# PuffRoute

<p align="center">
  <img src="Resources/PuffRoute.png" width="144" alt="PuffRoute icon">
</p>

PuffRoute 是一个轻量的原生 macOS 代理状态面板，用来查看 Mihomo/Clash Verge
的核心、混合端口和 TUN 状态，并提供结构化健康检查与可选的 PF Kill Switch。

## 功能

- 原生 SwiftUI 状态面板
- 检测 `verge-mihomo`、mixed 端口与 TUN 路由
- 检查代理出口 IP、常用 AI 站点和外网连通性
- 以独立 PF anchor 实现可开关的防泄漏规则
- 不覆盖其他 PF anchor；关闭时只清空 PuffRoute 自己的规则

## 系统要求

- macOS 13 或更高版本
- Xcode Command Line Tools
- 使用 Mihomo 核心的代理客户端（默认进程名 `verge-mihomo`）
- 默认 mixed 端口：`127.0.0.1:7890`

## 构建

```bash
chmod +x Scripts/*.sh
Scripts/build.sh
open build/PuffRoute.app
```

构建结果位于 `build/PuffRoute.app`，采用本机 ad-hoc 签名。

## 安装

```bash
Scripts/install.sh
```

默认安装到 `~/Applications/PuffRoute.app`，辅助脚本安装到：

- `~/.local/bin/puffroute-check`
- `~/.local/bin/puffroute-killswitch`
- `~/.local/share/puffroute/`

## 配置

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

## 可选：PF Kill Switch

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

## 隐私与安全

- 健康检查会通过已配置的本地代理访问公开 IP 查询服务和测试站点。
- PuffRoute 不上传配置，不收集遥测，也不保存浏览记录。
- 管理员权限仅用于读取或修改 PuffRoute 自己的 PF anchor。
- 发布前请不要提交 `~/.config/puffroute/config`。

## 项目状态

这是一个面向个人 macOS 代理环境的小工具。不同代理客户端、端口和 PF 网络接口
可能需要调整配置。欢迎通过 Issue 报告可复现的问题。
