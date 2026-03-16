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
