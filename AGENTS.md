# AGENTS.md

## Docker 镜像分层策略

本项目使用两层 Docker 镜像构建，一层为Base镜像，仅存放稳定、低频变动的组件；一层为动态层，仅包含绑定了自动更新检测（`check-update.yml`）的组件。

在新加入依赖的时候，如果用户没说放入动态层，则默认放入Base镜像

## CI Workflow

| Workflow | 触发条件 | 作用 |
|---|---|---|
| `build-base.yml` | `Dockerfile.base` 或 `docker/**` 变更 / 手动 | 构建 base 镜像，推送 `:base` 标签 |
| `docker-build.yml` | `Dockerfile` 变更 / 自动更新触发 / 手动 | 构建动态层，推送版本标签 |
| `check-update.yml` | 定时 cron / 手动 | 检测 opencode、code-server、codex 版本更新，触发 `docker-build.yml` |

需要做触发黑名单，针对仅配置部署文件、说明文档修改的时候不会触发构建，例如README.md、docker-compose.yml这类

## 文件布局架构

项目按职责划分为四个顶层模块：

| 目录 | 职责 | 说明 |
|---|---|---|
| `base/` | 基础依赖 | 存放底层工具和依赖库组件（如 microwarp 代理）。修改内部项目时请优先阅读对应目录下的 `AGENTS.md` |
| `backend/` | 控制台后端 | OpenCode serve 相关的后端服务逻辑 |
| `frontend/` | 控制台前端 | code-server 相关的前端服务逻辑 |
| `docker/` | Docker 启动 | 镜像启动文件（entrypoint.sh、healthcheck.sh）和进程管理配置（supervisord.conf） |