# AGENTS.md

## Docker 镜像分层策略

本项目使用两层 Docker 镜像构建，一层为Base镜像，仅存放稳定、低频变动的组件；一层为动态层，仅包含绑定了自动更新检测（`check-update.yml`）的组件。

在新加入依赖的时候，如果用户没说放入动态层，则默认放入Base镜像

## CI Workflow

| Workflow | 触发条件 | 作用 |
|---|---|---|
| `build-base.yml` | `Dockerfile.base` / `docker/**` / `backend/**` / `frontend/**` 变更 / 每周定时 / 手动 | 构建 base 镜像，推送 `:base` 标签，完成后级联触发动态层（沿用上次 release 锁定版本） |
| `docker-build.yml` | `Dockerfile` 变更 / 自动更新触发 / 手动 | 构建动态层，推送版本标签 |
| `check-update.yml` | 定时 cron / 手动 | 检测 opencode、code-server、codex、serena、claude-code 版本更新，触发 `docker-build.yml`；检测到更新时按 app 维度发送飞书"发现新版本"卡片 |
| `notify.yml` | `workflow_run`（监听 `build-base.yml` / `docker-build.yml` 完成） | 上游构建完成后发送飞书"构建结果"卡片（success / failure 两套模板） |

### 飞书通知拆分

飞书通知按事件类型拆成两条互不重叠的链路，**不要复用 `notify.yml` 处理更新检测**——`workflow_run` 只能拿到上游 `conclusion`，读不到 check-update 内部的版本对比结果，所以更新通知必须由 `check-update.yml` 自己发。

| 链路 | 工作流 | 卡片模板 | 版本 | 触发时机 | 模板变量 |
|---|---|---|---|---|---|
| 构建结果通知 | `notify.yml` | `AAqv2e8wrOFTm`（success）/ `AAqv27Co32Y8H`（failure） | `1.0.4` | Base / 动态层构建完成 | `Project_Name` / `Branch` / `Time` / `Actions_name` |
| 发现新版本通知 | `check-update.yml` | `AAqv2jtyQI8ay` | `1.0.5` | check-update 检测到任意 app 有更新（每个 app 一张卡片） | `App_Name` / `Old_Version` / `New_Version` / `Changelog_URL` / `Time` |

两条链路共用三个 secrets：`FEISHU_APP_ID` / `FEISHU_APP_SECRET` / `FEISHU_USER_ID`，并遵循统一的隐私约束（token `::add-mask::`、不打印 PAYLOAD、只回显业务 `code`/`msg`）。

### 触发归属原则

- **`docker/**`（启动脚本、supervisord 配置）属于 Base 层**：被 `Dockerfile.base` 直接 COPY，改动只触发 `build-base.yml`，Base 构建完成后通过 `trigger-dynamic` job 用上次 release 锁定的版本号级联重建动态层。
- **`Dockerfile`（动态层）只触发 `docker-build.yml`**：它不依赖 `docker/**` 之外的内容，单独改动不应带动 Base 层。
- **黑名单（不触发任何构建）**：README.md、docker-compose.yml、AGENTS.md、`.github/**`、`参考项目/**` 等纯文档/部署配置。`paths:` 白名单本身就是黑名单——只有列出的路径才会触发构建。

## 文件布局架构

项目按职责划分为四个顶层模块：

| 目录 | 职责 | 说明 |
|---|---|---|
| `base/` | 基础依赖 | 存放底层工具和依赖库组件（如 microwarp 代理）。修改内部项目时请优先阅读对应目录下的 `AGENTS.md` |
| `backend/` | 控制台后端 | OpenCode serve 相关的后端服务逻辑 |
| `frontend/` | 控制台前端 | code-server 相关的前端服务逻辑 |
| `docker/` | Docker 启动 | 镜像启动文件（entrypoint.sh、healthcheck.sh）和进程管理配置（supervisord.conf） |

## 如何验收编译

> 如果用户没说不验证则一律根据以下方法判断，请勿在本地直接编译/运行Docker，由于当前本身位于Docker内部

1. Commit
2. Push
3. 直接盯着对应工作流的运行，Base层和动态层均要长时间看