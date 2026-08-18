# AGENTS.md

## Docker 镜像分层策略

本项目使用三层 Docker 镜像构建（自底向上）：

1. **Base 层**（`Dockerfile.base` → `:base`）：仅存放稳定、低频变动的组件（工具链、运行时库、全局 npm/Python 包、Playwright 浏览器等），月级变动。
2. **桌面层**（`Dockerfile.desktop` → `:desktop`）：xrdp/XFCE4 远程桌面、Sarasa 字体、Fluent 主题、desktop 用户及桌面配置，周级变动。`FROM :base`。
3. **动态层**（`Dockerfile` → release tag）：仅包含绑定了自动更新检测（`check-update.yml`）的版本类组件，天级变动。`FROM :desktop`。

在新加入依赖的时候，如果用户没说放入哪层，则按性质判断：纯桌面视觉/远程桌面组件放桌面层，其余默认放入 Base 层。

### 触发归属原则

- **Base 层**：`Dockerfile.base`、`base/**`、以及 `docker/` 中 Base 归属的启动文件（entrypoint.sh / healthcheck.sh / supervisord.conf / init-warp.sh）改动触发 `build-base.yml`；Base 构建完成后通过 `trigger-desktop` job 级联重建桌面层，桌面层再级联重建动态层（版本号取上次 release 锁定值）。
- **桌面层**：`Dockerfile.desktop`、`desktop/**`、`docker/init-desktop.sh`、`docker/xrdp-startwm.sh` 改动只触发 `build-desktop.yml`，Base 层完全复用缓存；桌面构建完成后通过 `trigger-dynamic` job 级联重建动态层。
- **`Dockerfile`（动态层）只触发 `docker-build.yml`**：它 `FROM` 桌面镜像，并额外 COPY 了 `docker/` 下的三个启动文件（entrypoint/healthcheck/supervisord.conf）用于覆盖下层同名文件——这些是稳定文件，其更新靠下层级联保证；动态层本身只新增版本类组件（opencode/claude-code 等），单独改 `Dockerfile` 不应带动下层。
- **`agent/**` 属于动态层**：`agent/ccpatch/` 存放 Claude Code 补丁脚本，由 `Dockerfile` 动态层在装完 Claude Code 后通过 `agent/run-ccpatch.sh`（glob 遍历，失败不阻断构建）自动执行；`agent/**` 已列入 `docker-build.yml` 的 paths 白名单，新增/修改补丁脚本会触发动态层重建。
- **黑名单（不触发任何构建）**：README.md、docker-compose.yml、AGENTS.md、`.github/**`、`参考项目/**` 等纯文档/部署配置。`paths:` 白名单本身就是黑名单——只有列出的路径才会触发构建。

## 文件布局架构

项目按职责划分为顶层模块：

| 目录 | 职责 | 说明 |
|---|---|---|
| `agent/` | Claude Code 补丁 | `ccpatch/` 存放 cli.js 补丁脚本，`run-ccpatch.sh` 为遍历执行器（动态层构建时调用，失败不阻断构建） |
| `base/` | 基础依赖 | 存放底层工具和依赖库组件等配置文件/脚本（目前仅含构建期一次性脚本，如 Go 模块预热），归属 Base 层 |
| `docker/` | Docker 启动 | 镜像启动文件、进程管理配置等涉及容器启动的文件。entrypoint/supervisord/健康检查/WARP 初始化归 Base 层；init-desktop.sh / xrdp-startwm.sh（桌面专属）归桌面层 |
| `desktop/` | 桌面环境 | XFCE4/xrdp 桌面环境的运行时配置、壁纸资源和桌面快捷方式（`.desktop`），归属桌面层 |

## 关于任务结束后的处理方式

若用户未说明不需要提交/推送，则默认完成需求后就提交并推送上云