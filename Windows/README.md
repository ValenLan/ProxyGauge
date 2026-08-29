# ProxyGauge for Windows

支持所有正式发布的 Windows 11（x64 与 ARM64）。Windows 10 会被明确拒绝启动。
发布包已包含 .NET 运行时，无需单独安装。
界面会跟随 Windows 的应用浅色/深色设置，并在运行中同步外观变化；High Contrast 模式优先。

## 快速开始

1. 运行与电脑架构匹配的 ProxyGauge MSI；安装过程会请求一次管理员授权，并创建开始菜单与公共桌面快捷方式
2. 从桌面或开始菜单启动 ProxyGauge，它会检查 Mihomo 本地控制接口、系统代理和常用回环端口
3. 确认识别出的客户端、mixed 入口和流量模式；失败时只需手动填写本机端口
4. 在代理核心已运行时明确开启“系统保护”，再运行“链路检测”

ProxyGauge 会读取 Mihomo/Clash Verge 的本地进程、端口、系统代理和 TUN 状态，并用三个
出口查询源交叉验证结果。链路检测不再把第三方 IP 风险分混入链路分，也不会在后台访问
风险情报网站。默认不会主动请求 Claude、ChatGPT、Gemini 的网页或 API，避免检测制造机器人式访问记录。
检测到 TUN 时还会验证 DNS 是否返回 `198.18.x.x` Fake-IP，避免只看见路由已接管却漏掉
域名规则实际不生效的问题。

主界面底部的“规则管理”可以预览、复制或导出独立的 Merge YAML。规则包不包含订阅
地址、节点或凭据；默认使用名为 `PROXY` 的策略组。常规链路报告只显示自动检测结果，
不包含登录账号判断或需要手动打开的检测网站。检测产生的网络请求只通过你设置的
本地代理发送。运行时会显示线性进度，完成后按关键链路权重给出 0–100 链路分。

“链路检测 → 方案”默认保持通用检测。已经配置独立策略组和第二个回环 mixed 入口时，
可以启用额外出口方案；ProxyGauge 会检查 Mihomo 本地 named pipe 中的策略组、域名规则和
中性延迟，再分别验证默认入口与额外入口的真实公网出口。控制接口的完整响应、
节点列表和原始配置不会写入报告或配置文件。

点击“IP 纯净度复核”后，ProxyGauge 会先询问是否使用系统默认浏览器打开 IPPure、IPCheck.ing、
BrowserLeaks、IPQS、Scamalytics 与 AbuseIPDB。确认后先经当前本地 mixed 入口读取出口 IP，
Scamalytics 与 AbuseIPDB 会直接进入带该 IP 的结果页；若读取失败则不打开这两个输入页。
部分网站可能要求人机验证；页面沿用当前浏览器会话与实际网络路径，ProxyGauge 不修改 Windows 系统代理。
各站结论由用户自行交叉阅读，不合并成统一总分，人工结果不计入链路分。

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

如果链路检测失败，请先确认 Clash Verge/Mihomo 正在运行，并核对 mixed 端口。
