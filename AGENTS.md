# AGENTS.md

## Docker 镜像分层策略

本项目使用两层 Docker 镜像构建，**新对话修改 Dockerfile 时必须遵守以下分层规则**。

### base 镜像（Dockerfile.base）

稳定、低频变动的组件，仅在手动修改 `Dockerfile.base` 或 `docker/` 目录时重建。

CI 推送为 `ghcr.io/zhongruan0522/opencode-docker:base`，长期缓存。

包含：
- 系统包（apt）、开发/诊断工具（lsof、jq、htop 等）
- Go SDK、Bun
- Android SDK、Gradle
- microsocks
- gh CLI
- Playwright MCP npm 包 + Chromium 浏览器
- Python 包（Pillow、scrapling）
- Docker CE（DinD）
- **固定版本的 npm 包**：`@z_ai/mcp-server@0.1.3`、`@larksuite/cli`

### 动态层（Dockerfile）

FROM base 镜像，仅包含绑定了自动更新检测（`check-update.yml`）的组件。

每次自动更新触发时只重建此文件，base 层完全复用缓存。

包含：
- `code-server`（check-update 检测）
- `opencode-ai`（check-update 检测）
- `@openai/codex`（check-update 检测）

### 判断规则

- 有自动更新检测的包 -> 动态层
- 固定版本、无自动检测的包 -> base 层
- 拿不准的，问用户

## CI Workflow

| Workflow | 触发条件 | 作用 |
|---|---|---|
| `build-base.yml` | `Dockerfile.base` 或 `docker/**` 变更 / 手动 | 构建 base 镜像，推送 `:base` 标签 |
| `docker-build.yml` | `Dockerfile` 变更 / 自动更新触发 / 手动 | 构建动态层，推送版本标签 |
| `check-update.yml` | 定时 cron / 手动 | 检测 opencode、code-server、codex 版本更新，触发 `docker-build.yml` |

改 `docker-compose.yml`、`README.md`、`.github/workflows/check-update.yml` 不会触发任何构建。
