<h1 align="center">⚡ Wait Monitor</h1>

<p align="center">
  <a href="#english">English</a>
</p>

<p align="center">
  轻量级服务器监控面板，实时监控你的基础设施
</p>

<p align="center">
  <a href="#快速开始">快速开始</a> ·
  <a href="#功能特性">功能特性</a> ·
  <a href="#支持平台">支持平台</a> ·
  <a href="https://github.com/nimeng1222/wait-release/releases">版本列表</a>
</p>

---

## ✨ 功能特性

| 模块 | 说明 |
|------|------|
| 🖥️ **实时监控** | 节点在线状态、CPU / 内存 / 磁盘 / 网络流量，Ping 延迟检测（ICMP / TCP / HTTP） |
| 💻 **远程终端** | WebSocket 全功能终端，自动重连，支持快捷键和剪贴板收发 |
| 🔔 **告警通知** | 离线 / 负载告警，支持 Telegram、Webhook、邮件等多种通道 |
| 💰 **订阅管理** | 续费提醒、过期预警、多币种成本统计，自动折算人民币 |
| ⚙️ **管理面板** | 主题系统（明暗切换 + 自定义上传）、账户安全（2FA / OAuth SSO）、会话管理、操作日志 |
| 🌐 **中英双语** | 内置中文 / English，运行时无缝切换 |
| 🎨 **多平台支持** | Agent 支持 Windows、Linux、macOS、FreeBSD 全平台 |

## 🚀 快速开始

一行命令，即刻部署：

```bash
curl -fsSL https://raw.githubusercontent.com/nimeng1222/wait-release/main/install-wait.sh -o install-wait.sh
bash install-wait.sh
```

安装完成后，访问 `http://<你的服务器IP>:25774` 进入管理面板。

> 💡 Agent 安装更简单 —— 进入管理后台的 **节点管理**，点击对应节点的 **一键安装脚本** 即可完成部署。

## 🖧 支持平台

| 组件 | 平台 |
|------|------|
| wait-monitor | linux/amd64, linux/arm64 |
| wait-agent | Windows / Linux / macOS / FreeBSD |

## 📦 发布版本

所有历史版本可在 [Releases](https://github.com/nimeng1222/wait-release/releases) 查看并下载。

## 📄 许可证

[LICENSE](./LICENSE.wait-main)

---

## English

<a href="#english">↑ Back to top</a>

<p>Wait Monitor is a lightweight server monitoring dashboard that provides real-time infrastructure tracking through a web-based admin panel.</p>

<p>Features include node status monitoring, remote terminal access, alert notifications, subscription billing management, multi-platform agent support, and built-in i18n (Chinese / English).</p>

<p>For more details, please refer to the Chinese section above or check the <a href="https://github.com/nimeng1222/wait-release/releases">Releases page</a>.</p>
