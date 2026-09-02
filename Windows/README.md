# ProxyGauge for Windows

支持所有正式发布的 Windows 11（x64 与 ARM64）。Windows 10 会被明确拒绝启动。
发布包已包含 .NET 运行时，无需单独安装。
界面会跟随 Windows 的应用浅色/深色设置，并在运行中同步外观变化；High Contrast 模式优先。

通过 npm 自动安装时，安全边界要求系统目录为默认的 `C:\Windows`；非 C 系统盘请使用仓库
提供的独立 PowerShell 安装器，它会从 Windows API 读取实际系统目录。

## 快速开始

1. 运行与电脑架构匹配的 ProxyGauge MSI；安装过程会请求一次管理员授权，并创建开始菜单与公共桌面快捷方式
2. 从桌面或开始菜单启动 ProxyGauge，它会检查 Mihomo 本地控制接口、系统代理、代表性本地路由和回环端口归属
3. 确认识别出的系统代理、PAC、TUN、其他 VPN 或 Mihomo mixed 入口；已检测到系统路径时不强制填写端口
4. 在代理核心已运行时按需明确开启“断网保护”

ProxyGauge 会读取 Mihomo/Clash Verge 的本地进程、端口、系统代理和 TUN 状态。主界面不会
在后台访问风险情报网站，也不会主动请求 Claude、ChatGPT、Gemini 的网页或 API。

主界面的“系统实际出口”卡遵循 Windows 当前系统代理、PAC、VPN、TUN 或直连路径，请求
`https://ipapi.co/json/` 读取出口 IP 与国家/地区/城市，并由 api.ipify.org 独立确认；两者
冲突、信息不完整或请求失败时，再按需查询 ipwho.is、ifconfig.me 与 ip.sb；只有在已获得响应的
独立来源中超过半数、且至少有两票确认同一地址时才显示结果。整次核验最多 15 秒。国家缺失时
不会单独显示城市。所有请求禁用缓存，
仅接受规范化的公网 IPv4/IPv6 地址。应用不查询、推断或保存住宅、机房、代理等网络类型；
应用也不持久化出口结果。无代理时，被请求的公网查询服务会看到真实公网 IP 和请求时间，
但不会收到本机代理端口、订阅、节点、凭据或检测历史。仪表盘处于前台时最多每 5 分钟
自动核验一次；切回应用、网络路径变化或手动刷新也会立即使旧结果失效并重新检测。

点击“IP 纯净度”后，ProxyGauge 会先询问是否使用系统默认浏览器打开 IPPure、IPCheck.ing、
BrowserLeaks 与 IPQS。应用不会预读 IP、不会把 IP 拼入网址，也不会读取或保存页面内容。
页面沿用当前浏览器会话与实际网络路径，ProxyGauge 不修改 Windows 系统代理；各站结论由
用户自行交叉阅读，不合并成统一总分。

## 配置位置

```text
%APPDATA%\ProxyGauge\config.json
```

删除该文件即可恢复默认设置。

## 系统保护

- MSI 安装自动启动的 `ProxyGaugeGuard` LocalSystem 服务；日常界面不以管理员运行
- 保护规则只匹配开启保护的 Windows 用户，不阻断系统服务或其他用户
- 允许回环、本地代理核心和识别到的 TUN 接口，拦截其余 IPv4/IPv6 直连
- 关闭窗口、退出界面、用户注销或界面崩溃不会关闭保护；持久 WFP 规则继续生效
- 如果 Mihomo/Clash 代理核心退出，Guard 仍保留直连拦截：结果是无法联网，不会回退到真实 IP 裸连
- 重启电脑后，服务会在用户登录前启动并校验持久规则
- 代理故障不会自动放行，避免把故障误判成用户同意暴露真实 IP
- 主界面的“关闭”会先显示真实 IP 暴露警告，只有用户再次确认才解除规则
- 卸载 MSI 会先停止服务并清除持久规则

界面损坏或无法启动时，在管理员终端运行独立恢复命令：

```powershell
& "C:\Program Files\ProxyGauge\ProxyGauge.Guard.exe" --emergency-off
```

如果恢复程序本身也损坏，管理员可运行
`sc.exe config ProxyGaugeGuard start= disabled` 后重启。BFE 不会在下次启动时装载属于已禁用
服务的 provider 规则；这只作为最后恢复手段。

## Windows 安全提醒

- ProxyGauge 使用系统自带 WFP，不安装内核驱动，也不修改 Windows Firewall 默认策略
- ProxyGauge 不收集遥测或浏览记录
- 个人构建未购买代码签名证书，Windows SmartScreen 可能在首次运行时显示提醒

如果代理状态异常，请先确认 Clash Verge/Mihomo 正在运行，并核对本地 mixed 入口与当前系统代理或 TUN。
