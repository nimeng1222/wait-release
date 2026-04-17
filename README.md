<p align="center">
  <h1 align="center">Wait Monitor</h1>
</p>

<p align="center">
  <b>EN</b> · <a href="#中文说明">中文说明</a>
</p>

---

**Wait Monitor** is an infrastructure monitoring system with a web-based admin dashboard, remote terminal, alert notifications, and subscription management.

<p align="center">
  <a href="#quick-start">Quick Start</a> ·
  <a href="#features">Features</a> ·
  <a href="#supported-platforms">Supported Platforms</a> ·
  <a href="#releases">Releases</a>
</p>

---

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/nimeng1222/wait-release/main/install-wait.sh -o install-wait.sh
bash install-wait.sh
```

## Features

- **Real-time Monitoring** -- Node status, CPU / RAM / Disk / Network traffic, Ping latency (ICMP / TCP / HTTP)
- **Remote Terminal** -- WebSocket-based full terminal with auto-reconnect and clipboard support
- **Alert Notifications** -- Offline / load alerts via Telegram, Webhook, Email and more
- **Subscription Management** -- Renewal alerts, multi-currency cost statistics
- **Admin Dashboard** -- Theme system, account security (2FA / OAuth SSO), session management, audit logs
- **i18n** -- Built-in Chinese / English, toggle at runtime
- **Dark Mode** -- Light and dark themes, custom theme upload supported

## Supported Platforms

| Component | Platforms |
|-----------|-----------|
| wait-monitor | linux/amd64, linux/arm64 |
| wait-agent | Windows / Linux / macOS / FreeBSD |

## Releases

See [Releases](https://github.com/nimeng1222/wait-release/releases) for all versions.

## License

[LICENSE](./LICENSE.wait-main)

---

## 中文说明

<p align="center">
  <a href="#english">English</a> · <b>中文</b>
</p>

---

**Wait Monitor** 是一套基础设施监控系统，提供 Web 管理面板、远程终端、告警通知和订阅管理功能。

<p align="center">
  <a href="#快速开始">快速开始</a> ·
  <a href="#功能特性">功能特性</a> ·
  <a href="#支持平台">支持平台</a> ·
  <a href="#发布版本">发布版本</a>
</p>

---

## 快速开始

```bash
curl -fsSL https://raw.githubusercontent.com/nimeng1222/wait-release/main/install-wait.sh -o install-wait.sh
bash install-wait.sh
```

安装完成后，访问 `http://<服务器IP>:8080` 进入管理面板。Agent 的安装可在后台管理页面的节点管理中一键操作。

## 功能特性

- **实时监控** -- 节点在线状态、CPU / 内存 / 磁盘 / 网络流量、Ping 延迟检测（ICMP / TCP / HTTP）
- **远程终端** -- WebSocket 全功能终端，支持自动重连和剪贴板收发
- **告警通知** -- 离线 / 负载告警，支持 Telegram、Webhook、邮件等通道
- **订阅管理** -- 续费提醒、过期预警、多币种成本统计
- **管理面板** -- 主题系统、账户安全（2FA / OAuth SSO）、会话管理、操作日志
- **中英双语** -- 内置中文 / English，运行时无缝切换
- **明暗主题** -- 支持亮色 / 暗色主题，可上传自定义主题

## 支持平台

| 组件 | 支持平台 |
|------|---------|
| wait-monitor | linux/amd64, linux/arm64 |
| wait-agent | Windows / Linux / macOS / FreeBSD |

## 发布版本

所有版本可在 [Releases](https://github.com/nimeng1222/wait-release/releases) 页面下载。

## 许可证

[LICENSE](./LICENSE.wait-main)
