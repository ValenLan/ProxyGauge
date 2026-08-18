# PuffRoute for Windows

## 快速开始

1. 双击 `PuffRoute.exe`
2. 点击右上角设置按钮
3. mixed 地址通常为 `127.0.0.1`，默认端口为 `7890`
4. 回到主界面刷新状态，或运行“健康检查”

PuffRoute 会读取 Mihomo/Clash Verge 的本地进程、端口、系统代理和 TUN 状态，并在
健康检查中分别显示网络归属、PeeringDB ASN 属性、IP 段用途、proxycheck.io 风险分与
ipapi.is / proxycheck.io 地址风险标签；三个出口查询源会交叉验证结果。默认不会主动
请求 Claude、ChatGPT、Gemini 的网页或 API，避免健康检查制造机器人式访问记录。
检测到 TUN 时还会验证 DNS 是否返回 `198.18.x.x` Fake-IP，避免只看见路由已接管却漏掉
域名规则实际不生效的问题。

主界面底部的“规则管理”可以预览、复制或导出独立的 Merge YAML。规则包不包含订阅
地址、节点或凭据；默认使用名为 `PROXY` 的策略组。健康报告还提供 BrowserLeaks、
IPhey、IPQS、Scamalytics 和 AbuseIPDB 的浏览器复核按钮，这些网站不会在后台自动访问。
Claude / ChatGPT 登录账户状态始终单独显示为“未验证”；公网入口可达不代表账户未被封禁。
健康检查产生的网络请求只通过你设置的本地代理发送。

## 配置位置

```text
%APPDATA%\PuffRoute\config.json
```

删除该文件即可恢复默认设置。

## Windows 安全提醒

- PuffRoute 不需要管理员权限
- PuffRoute 不修改 Windows Firewall
- PuffRoute 不收集遥测或浏览记录
- 个人构建未购买代码签名证书，Windows SmartScreen 可能在首次运行时显示提醒

如果健康检查失败，请先确认 Clash Verge/Mihomo 正在运行，并核对 mixed 端口。
