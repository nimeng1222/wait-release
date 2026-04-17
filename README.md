# Wait Monitor

开源基础设施监控系统，支持节点管理、实时监控、远程终端、负载告警和订阅管理。

## 项目架构

| 组件 | 仓库 | 说明 |
|------|------|------|
| **Wait Monitor** (主控) | [nimeng1222/wait-monitor](https://github.com/nimeng1222/wait-monitor) | Go 后端 + 内嵌前端 Web UI |
| **Wait Agent** (节点) | [nimeng1222/wait-agent](https://github.com/nimeng1222/wait-agent) | 部署在各节点的监控 Agent |
| **Wait Web** (前端) | [nimeng1222/wait-web-next](https://github.com/nimeng1222/wait-web-next) | React + TypeScript 管理面板 |

## 快速开始

### 一键安装主控

```bash
curl -fsSL https://raw.githubusercontent.com/nimeng1222/wait-release/main/install-wait.sh -o install-wait.sh
bash install-wait.sh
```

### 一键安装 Agent

```bash
curl -fsSL https://raw.githubusercontent.com/nimeng1222/wait-release/main/install-agent.sh -o install-agent.sh
bash install-agent.sh
```

### 自定义安装地址

如果从其他仓库分发，可通过环境变量覆盖：

```bash
WAIT_MAIN_RELEASE_REPO_URL="https://github.com/yourname/releases" bash install-wait.sh
WAIT_AGENT_RELEASE_REPO_URL="https://github.com/yourname/releases" bash install-agent.sh
```

## 功能特性

### 实时监控
- 节点在线状态、CPU / 内存 / 磁盘 / 网络流量
- Ping 延迟检测（ICMP / TCP / HTTP）
- 网络质量趋势图

### 远程终端
- WebSocket 桥接，支持 xterm.js 全功能终端
- 自动重连、快捷键支持、剪贴板收发

### 告警通知
- 离线通知、负载通知（CPU / RAM / Disk / 网络）
- 支持多种消息通道：Telegram、Webhook、邮件等
- 节点级独立开关和宽限期

### 订阅管理
- 续费提醒、过期预警
- 多币种成本统计，自动折算 CNY
- 月 / 年成本一览

### 管理面板
- 站点设置、主题管理（上传 / 导入 / 切换）
- 账户安全（密码 / 2FA / OAuth SSO）
- 会话管理、操作日志
- 批量命令执行

### 国际化 & 主题
- 内置中文 / English 双语切换
- 明 / 暗主题，支持自定义主题上传
- 响应式设计，适配移动端

## 技术栈

**主控**: Go 1.24 + Gin + WebSocket + SQLite

**前端**: React 19 + TypeScript + Vite 6 + Tailwind CSS 4 + Radix UI + xterm.js

**Agent**: Go 1.23 + WebSocket + gRPC，支持 Windows / Linux / macOS / FreeBSD 全平台

## Releases

所有发布版本均可在 [Releases](https://github.com/nimeng1222/wait-release/releases) 页面下载。

| 组件 | 当前版本 | 平台 |
|------|---------|------|
| wait-monitor | v0.1.15 | linux/amd64, linux/arm64 |
| wait-agent | v0.0.6 | Windows / Linux / macOS / FreeBSD 全平台 |

## 许可证

- wait-monitor: [LICENSE](https://raw.githubusercontent.com/nimeng1222/wait-release/main/LICENSE.wait-main)
- wait-agent: [LICENSE](https://raw.githubusercontent.com/nimeng1222/wait-release/main/LICENSE.wait-agent)
