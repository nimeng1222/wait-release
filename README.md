# Wait Monitor Release

Wait Monitor 是一个轻量级自托管服务器监控系统。本仓库是公开分发仓库，提供安装脚本和聚合发布产物；主控服务与 Agent 的源码分别维护在独立仓库中。

- 主控服务发布源：`nimeng1222/wait-monitor`
- Agent 发布源：`nimeng1222/wait-agent`
- 公开安装与镜像下载：`nimeng1222/wait-release`

## 功能概览

- 实时监控：节点在线状态、CPU、内存、磁盘、网络流量。
- 节点探针：Agent 通过长连接上报状态，支持 Linux 和 Windows 产物。
- Web 管理面板：主控二进制内嵌前端，部署后直接访问浏览器管理。
- 远程终端：通过管理面板连接节点终端。
- 告警通知：离线、负载等事件通知。
- 账户安全：登录、会话、2FA、OAuth SSO、审计日志。
- 安装安全：安装脚本下载二进制后执行 SHA-256 校验与 pinned-key ECDSA 签名校验，任一校验失败都会拒绝安装。

## 快速安装主控

支持系统：Linux `amd64` / `arm64`，推荐使用带 systemd 的发行版。

```bash
curl -fsSL https://raw.githubusercontent.com/nimeng1222/wait-release/main/install-wait.sh -o install-wait.sh
sudo bash install-wait.sh
```

脚本会打开交互菜单，可选择：

- 安装 `wait-monitor`
- 升级 `wait-monitor`
- 卸载 `wait-monitor`
- 查看状态、日志、重启或停止服务
- 卸载 Agent

默认安装信息：

| 项目 | 默认值 |
| --- | --- |
| 访问端口 | `25774` |
| 安装目录 | `/opt/wait-monitor` |
| 数据目录 | `/opt/wait-monitor/data` |
| 二进制路径 | `/opt/wait-monitor/wait-monitor` |
| systemd 服务 | `wait-monitor.service` |
| 运行用户 | 优先使用 `wait-monitor` 专用用户，必要时回退到 `root` |

安装完成后访问：

```text
http://<server-ip>:25774
```

首次安装会在终端输出初始管理员账号密码。凭据文件位于：

```text
/opt/wait-monitor/data/initial-admin-credentials.json
```

首次成功登录后，服务端会自动删除该初始凭据文件。

## 安装指定版本

默认安装最新 release。如果需要固定版本：

```bash
curl -fsSL https://raw.githubusercontent.com/nimeng1222/wait-release/main/install-wait.sh -o install-wait.sh
sudo WAIT_MAIN_RELEASE_VERSION=v0.1.33 bash install-wait.sh
```

也可以切换下载源：

```bash
sudo WAIT_MAIN_RELEASE_REPO_URL="https://github.com/nimeng1222/wait-release/releases" \
  WAIT_MAIN_RELEASE_VERSION="v0.1.33" \
  bash install-wait.sh
```

## 安装 Agent

Agent 通常不需要手动拼命令。推荐流程：

1. 先安装并登录 Wait Monitor 主控。
2. 在管理面板中创建或打开节点。
3. 使用页面生成的一键安装命令安装 Agent。

Agent 安装脚本需要主控地址和节点 token：

```bash
curl -fsSL https://raw.githubusercontent.com/nimeng1222/wait-release/main/install-agent.sh -o install-agent.sh
sudo bash install-agent.sh --endpoint "https://example.com" --token "YOUR_NODE_TOKEN"
```

Agent 默认信息：

| 项目 | 默认值 |
| --- | --- |
| 安装目录 | `/opt/wait` |
| 二进制路径 | `/opt/wait/agent` |
| systemd 服务 | `wait-agent.service` |
| 运行用户 | 优先使用 `wait-agent` 专用用户 |

可选参数：

```bash
sudo bash install-agent.sh \
  --endpoint "https://example.com" \
  --token "YOUR_NODE_TOKEN" \
  --install-dir "/opt/wait" \
  --install-service-name "wait-agent"
```

## 环境变量

主控安装脚本：

| 变量 | 说明 |
| --- | --- |
| `WAIT_MAIN_RELEASE_REPO_URL` | 主控二进制下载源，默认使用本仓库 release |
| `WAIT_MAIN_RELEASE_VERSION` | 指定主控版本，例如 `v0.1.33`；为空时使用 latest |

Agent 安装脚本：

| 变量 | 说明 |
| --- | --- |
| `WAIT_AGENT_RELEASE_REPO_URL` | Agent 二进制下载源，默认使用本仓库 release |
| `WAIT_AGENT_SKIP_CHECKSUM` | （已弃用）设置为 `1` 跳过 SHA-256 完整性校验，不推荐，仅用于紧急排障。旧实现会连带跳过签名校验，现已拆分为独立变量。 |
| `WAIT_AGENT_SKIP_SIGNATURE` | 设置为 `1` 跳过 ECDSA 签名校验，与 `WAIT_AGENT_SKIP_CHECKSUM` 独立。不推荐，仅用于紧急排障。 |

## 常用运维命令

主控服务：

```bash
sudo systemctl status wait-monitor
sudo journalctl -u wait-monitor -f
sudo systemctl restart wait-monitor
sudo systemctl stop wait-monitor
```

Agent 服务：

```bash
sudo systemctl status wait-agent
sudo journalctl -u wait-agent -f
sudo systemctl restart wait-agent
sudo systemctl stop wait-agent
```

重新打开主控安装管理菜单：

```bash
sudo bash install-wait.sh
```

## 发布产物

本仓库 release 聚合提供以下类型产物：

- `wait-linux-amd64`
- `wait-linux-arm64`
- `wait-agent-linux-amd64`
- `wait-agent-linux-arm64`
- `wait-agent-windows-amd64.exe`
- `wait-agent-windows-arm64.exe`
- `*.sha256`
- `SHA256SUMS.txt`
- `MANIFEST.txt`
- `PROVENANCE.json`
- `SBOM.*`
- `LICENSE.*` / `NOTICE.*`

安装脚本会优先下载校验文件并验证二进制完整性。主控安装脚本在校验通过后才会执行二进制兼容性检查。

## GitHub Actions 发版

正式发版建议使用本仓库的 `Unified Release` workflow，不再从个人电脑直接执行发布。

默认版本策略会先显示 release plan：主控包包含后端和内嵌前端，因此每次正式发布提升
主控补丁版本；Agent 只有在所选源码 commit 与当前 Agent release tag 不同时才提升版本。
前端或后端单独变化时，Agent 保持原版本且不会重复创建 Agent release。确需重发未变化的
Agent 时使用 `force_agent_release`。`reuse_release_versions` 会重发主控和 Agent 两条版本线，
因此必须同时显式开启 `allow_release_clobber`。

### 必要前置项

1. 前端源码需要在 GitHub 仓库中可 checkout。默认 workflow 使用：

   ```text
   nimeng1222/wait-web-next
   ```

   前端仓库固定为 `nimeng1222/wait-web-next`；workflow 不接受任意仓库名称输入。

2. 在 `nimeng1222/wait-release` 仓库配置以下 Secrets：

   | Secret | 说明 |
   | --- | --- |
   | `WAIT_RELEASE_SIGNING_KEY_PEM` | 仅正式发布需要。ECDSA release 签名私钥 PEM 内容，必须匹配安装脚本内置公钥 |
   | `RELEASE_GITHUB_TOKEN` | 用于 checkout 源码仓库并创建四个 GitHub Release（分布在三个仓库）的 token |

   `RELEASE_GITHUB_TOKEN` 至少需要能读取 `wait-monitor`、`wait-agent`、前端仓库，并能对 `wait-monitor`、`wait-agent`、`wait-release` 创建 Release / 上传资产。Fine-grained PAT 推荐授予这些仓库的 `Contents: Read and write` 权限；classic PAT 可使用 `repo` scope。

### 触发方式

进入 GitHub：

```text
nimeng1222/wait-release -> Actions -> Unified Release -> Run workflow
```

常用输入：

| 输入 | 默认值 | 说明 |
| --- | --- | --- |
| `main_ref` | `main` | 要发布的 `wait-monitor` ref |
| `agent_ref` | `main` | 要发布的 `wait-agent` ref |
| `web_ref` | `main` | 要嵌入的前端 ref |
| `publish_releases` | `true` | 设为 `false` 时只 dry-run 构建并上传 `release-output` artifact；不读取正式签名私钥，而是生成一次性临时密钥供产物自检 |
| `reuse_release_versions` | `false` | 默认智能规划；设为 `true` 时复用并重发主控与 Agent 当前版本，必须同时开启覆盖 |
| `allow_release_clobber` | `false` | 默认禁止覆盖已有 release 资产 |
| `main_version` / `agent_version` | 空 | 显式指定版本时使用，例如 `v0.1.35` |
| `force_agent_release` | `false` | Agent 源码未变化时仍强制重发 Agent 专属 release |

workflow 会固定使用 Node 22、Go 1.26.5 和已验证签名的 Zig 0.14.1，构建完成后会验签 `SHA256SUMS.txt`、主控二进制和 agent 二进制，并把 `release-output` 作为短期 artifact 留档。

## 安全说明

- 请优先使用 HTTPS 下载脚本和 release 资产。
- 不建议跳过 SHA-256 校验。
- 如需使用低于 `1024` 的端口，脚本会通过 systemd 的 `AmbientCapabilities=CAP_NET_BIND_SERVICE` 授权专用服务用户绑定端口。
- 升级主控时脚本会先备份当前二进制；新版本下载、校验、兼容性检查或启动失败时会尝试回滚。

## English

Wait Monitor is a lightweight self-hosted server monitoring system. This repository is the public distribution repository for installers and release artifacts.

Quick install:

```bash
curl -fsSL https://raw.githubusercontent.com/nimeng1222/wait-release/main/install-wait.sh -o install-wait.sh
sudo bash install-wait.sh
```

The server listens on port `25774` by default. After installation, open:

```text
http://<server-ip>:25774
```

The Agent should normally be installed from the admin panel, which generates the correct endpoint and token command for each node.
