# wait-release

这是公开产物分发目录的本地模板。

用途：
- 对外公开安装脚本
- 对外公开主控/agent 二进制产物
- 保持源码仓库 `wait-monitor` / `wait-agent` / `wait-web-next` 私有

## 推荐公开仓库结构

```text
wait-release/
  install-wait.sh
  install-agent.sh
  README.md
  releases/latest/download/
    wait-linux-amd64
    wait-linux-arm64
    wait-agent-linux-amd64
    wait-agent-linux-arm64
    ...
    LICENSE.wait-main
    LICENSE.wait-agent
    NOTICE.wait-main
    NOTICE.wait-agent
```

## 安装方式

### 主控

```bash
curl -fsSL https://raw.githubusercontent.com/<your-user>/wait-release/main/install-wait.sh -o install-wait.sh
bash install-wait.sh
```

### agent

```bash
curl -fsSL https://raw.githubusercontent.com/<your-user>/wait-release/main/install-agent.sh -o install-agent.sh
bash install-agent.sh
```

## 说明

当前脚本默认下载源已经改成：
- `https://github.com/nimeng1222/wait-release/releases`

如果你未来更换分发仓库，可以用环境变量覆盖：
- `WAIT_MAIN_RELEASE_REPO_URL`
- `WAIT_AGENT_RELEASE_REPO_URL`
