# OpenCode Docker

OpenCode 的 Docker 镜像，包含常用开发工具。

## 包含工具

- Node.js 22
- Python 3
- Git
- Go 1.22
- Vim / Nano
- Tmux
- OpenCode CLI (`opencode-ai`)

## 环境变量

| 变量 | 说明 |
|------|------|
| `OPENCODE_SERVER_USERNAME` | 服务端用户名（必填） |
| `OPENCODE_SERVER_PASSWORD` | 服务端密码（必填） |

容器启动时必须设置这两个变量，否则会立即退出。

## 目录权限（重要）

镜像默认以非 root 用户 `app`（uid=10001）运行。你挂载 `./workspace:/workspace`、`./config:/home/app/.config/opencode` 时，宿主机目录需要对 uid=10001 可写，否则会出现 `Permission denied`。

推荐使用 ACL（不改变目录归属，且对后续新建文件也生效）：

```bash
mkdir -p workspace config

# Debian/Ubuntu
sudo apt-get update && sudo apt-get install -y acl

sudo setfacl -R -m u:10001:rwX -m m:rwX ./workspace ./config
sudo setfacl -R -d -m u:10001:rwX -m m:rwX ./workspace ./config
```

如果你的文件系统不支持 ACL（提示 `Operation not supported`），可以退回到：

```bash
sudo chown -R 10001:10001 ./workspace ./config
```

## 使用方法

### Docker 命令

```bash
docker run -d \
  -e OPENCODE_SERVER_USERNAME=your_username \
  -e OPENCODE_SERVER_PASSWORD=your_password \
  -p 127.0.0.1:4096:4096 \
  -v $(pwd)/workspace:/workspace \
  -v $(pwd)/config:/home/app/.config/opencode \
  ghcr.io/zhongruan0522/opencode-docker:latest
```

### Docker Compose

```yaml
version: '3.8'
services:
  opencode:
    image: ghcr.io/zhongruan0522/opencode-docker:latest
    user: "10001:10001"
    environment:
      - OPENCODE_SERVER_USERNAME=your_username
      - OPENCODE_SERVER_PASSWORD=your_password
    ports:
      - "127.0.0.1:4096:4096"
    volumes:
      - ./workspace:/workspace
      - ./config:/home/app/.config/opencode
    restart: unless-stopped
```

启动：

```bash
docker compose up -d
```

## 自动更新

项目包含 GitHub Actions 工作流，每天自动检测 [anomalyco/opencode](https://github.com/anomalyco/opencode) 的最新版本并触发构建。
