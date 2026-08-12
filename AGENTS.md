# AGENTS.md

## Docker 镜像分层策略

本项目使用两层 Docker 镜像构建，一层为Base镜像，仅存放稳定、低频变动的组件；一层为动态层，仅包含绑定了自动更新检测（`check-update.yml`）的组件。

在新加入依赖的时候，如果用户没说放入动态层，则默认放入Base镜像

### 触发归属原则

- **`docker/**` 与 `desktop/**` 属于 Base 层**：被 `Dockerfile.base` 直接 COPY（`docker/` 放启动/进程管理脚本，`desktop/` 放 XFCE4 桌面配置与资源），改动只触发 `build-base.yml`，Base 构建完成后通过 `trigger-dynamic` job 用上次 release 锁定的版本号级联重建动态层。
- **`Dockerfile`（动态层）只触发 `docker-build.yml`**：它 `FROM` Base 镜像，并额外 COPY 了 `docker/` 下的三个启动文件（entrypoint/healthcheck/supervisord.conf）用于覆盖 Base 层同名文件——这些是稳定文件，其更新靠 Base 层级联保证；动态层本身只新增版本类组件（opencode/claude-code 等），单独改 `Dockerfile` 不应带动 Base 层。
- **黑名单（不触发任何构建）**：README.md、docker-compose.yml、AGENTS.md、`.github/**`、`参考项目/**` 等纯文档/部署配置。`paths:` 白名单本身就是黑名单——只有列出的路径才会触发构建。

## 文件布局架构

项目按职责划分为三个顶层模块：

| 目录 | 职责 | 说明 |
|---|---|---|
| `base/` | 基础依赖 | 存放底层工具和依赖库组件等配置文件/脚本（目前仅含构建期一次性脚本，如 Go 模块预热） |
| `docker/` | Docker 启动 | 镜像启动文件、进程管理配置等涉及容器启动的文件（entrypoint、supervisord、健康检查、xrdp 会话、WARP/桌面初始化脚本） |
| `desktop/` | 桌面环境 | XFCE4/xrdp 桌面环境的运行时配置、壁纸资源和桌面快捷方式（`.desktop`） |

## 关于任务结束后的处理方式

若用户未说明不需要提交/推送，则默认完成需求后就提交并推送上云