# 环境检查报告（2026-09-26）

对本镜像（OpenCode-Docker，当前运行的 slim 变体容器）直接部署的全部包、项目及依赖做了一次完整性 / 版本 / 配置匹配 / 可运行性检查。AIAgent、Serean 两个项目按要求未检查。

## 检查范围与方法

- **Base 层**：Go/Rust/Java(Temurin 21)/Android SDK/Flutter/Gradle 工具链，Node 24 + 全局 npm 包（Playwright MCP、wrangler、eas-cli、lark-cli/lark-mcp、TS 全家桶、办公四件套依赖等），Python 3.11 + install-python.sh 全清单导入与 `pip check`，Go 模块预热缓存（按 new-api go.sum `go mod verify`），Playwright 浏览器缓存与 Python 侧修订版对齐，Google Chrome，Docker CE，FFmpeg/whisper-cli，APK 工具链（apktool/jadx/dex2jar/uber-apk-signer），逆向工具（radare2/anything-analyzer），LibreOffice/Inkscape/ImageMagick/Ghostscript/pandoc，Wine/mono/NSIS，mihomo，CodeGraph，Hyperframes（`doctor --json` 全项），uv，Bun/pnpm/yarn/corepack，locale，profile.d 与镜像 ENV 同步。
- **动态层**：code-server、serena-agent、Codex、Claude Code（+ccline+ccpatch）、codex-security、Antigravity（agy）、opencode、openchamber。
- **服务运行状态**：supervisord 托管的 code-server(:8080)、openchamber(:4096)、serena(:9121)，entrypoint 直接拉起的 sshd(:2223)、mihomo(TUN)，以及 Docker HEALTHCHECK 脚本本身。

## 结论：发现 3 个问题

### 问题 1：radare2 完全缺失（命令不存在）

- **现象**：`r2` / `radare2` / `rabin2` 均为 `command not found`；`dpkg -l` 中无 radare2 包；全盘搜索无 radare2 二进制。
- **位置**：`Dockerfile.base` 第 204-219 行（radare2 安装段，位于 **builder 阶段**）。
- **影响**：Base 层宣称内置的逆向 CLI 工具链实际不存在，容器内无法使用。

### 问题 2：anything-analyzer 无法启动（AppImage 挂载失败）

- **现象**：执行 `/usr/local/bin/anything-analyzer` 报 `fuse: failed to exec fusermount: No such file or directory` 后退出（exit 127），AppImage 运行时无法挂载自身。
- **位置**：`Dockerfile.base` 第 459-460 行附近（final 阶段只安装了 `libfuse2` 库，未安装提供 `fusermount` 二进制的 `fuse` 包）；wrapper 位于 `Dockerfile.base` 第 218 行。
- **影响**：Base 层内置的 Anything Analyzer 逆向工具完全不可用。

### 问题 3：Docker 健康检查永远失败（healthcheck.sh 恒返回 unhealthy）

- **现象**：`/usr/local/bin/healthcheck.sh` 无任何输出、以 exit 3 退出。原因：`supervisorctl status` 在存在任何非 RUNNING 程序时按 LSB 语义返回 3（"program is not running"），而 `dockerd` 按设计默认不自启（`autostart=false`，见 `base/supervisord.conf` 第 23 行）；脚本第 5 行 `set -e` 使其在第一条命令就终止，三个 grep 健康判据从未被执行。
- **位置**：`base/healthcheck.sh` 第 5-7 行（`set -e` + `STATUS=$(supervisorctl ... status)`）。
- **影响**：默认部署（不开 dockerd）下容器状态恒为 `unhealthy`，健康检查失去意义，还可能触发编排层误重启。

## 排查中排除的疑点（非问题）

- `eas-cli` 二进制名实为 `eas`（`eas --version` → 24.8.0），非缺失。
- `zipalign` / `d2j-dex2jar` 无 `--version` 选项，输出 usage 属正常。
- `yarn` 首次运行经 corepack 联网下载 1.22.22（镜像未预热 corepack 缓存，联网环境行为正常；离线首跑会失败，本次不作为缺陷，仅记录）。
- mihomo 为纯 TUN 模式（Meta 设备 UP、DNS :53、配置 `mihomo -t` 通过），本地本就无 7890 HTTP 代理端口。
- Hyperframes doctor 仅 "Docker running" 一项 false，属文档明确的运行期状态（dockerd 默认不自启）。
- `dockerd` supervisor 程序 STOPPED 为设计行为（`ENABLE_DOCKERD=1` 才自启）。

## 检查通过项摘要（节选）

Go 1.26.4（gopls/govulncheck、new-api 模块 verify 全通过）、Rust 1.95.0 + nightly-2025-09-18（clippy/rustfmt/rust-src/llvm-tools 全齐）、Temurin 21.0.12（JAVA_HOME 软链正确）、Android SDK（platforms 30/34/35/36 + build-tools 30.0.2/35.0.1）、Flutter 3.44.4、Gradle 9.0.0、Node 24.10.0、Bun 1.3.14、pnpm 12.6.0、yarn 1.22.22、Playwright MCP 0.0.70（Chromium 1243 + Python 侧 v1228 符号链对齐）、Chrome 153、wrangler 4.141.0、eas 24.8.0、lark-cli 1.0.96、lark-mcp 0.5.1、codegraph 1.6.0、hyperframes 0.8.78、uv 0.12.19、mihomo 1.19.30、ffmpeg/ffprobe 5.1.9、whisper-cli、code-server 4.139.1、serena 1.7.0（MCP /mcp 端点 POST 200）、codex 0.157.1、Claude Code 2.1.283、ccline 1.1.2、codex-security 0.1.31、agy 1.2.11、opencode 1.18.32、openchamber 2.0.2（:4096 返回 200）、Python 全清单导入零失败且 `pip check` 无冲突、torch 2.14.0+cpu、scrapling 0.4.12、办公四件套 Node 依赖全部可解析、Electron win32 缓存 41.7.1、LibreOffice 7.4.7、Wine 8.0、mono 6.8、NSIS 3.08、zh_CN.UTF-8 locale、profile.d 与镜像 ENV 一致。

## 修复记录（同日完成，均已本地验证）

| 问题 | 根因（子代理排查确认） | 修复 | 本地验证 |
|---|---|---|---|
| 1. radare2 缺失 | deb 包装在 builder 阶段的 `/usr`，final 阶段的 COPY（`/usr/local`、`/opt` 等 5 个路径）不覆盖 `/usr`，产物从未进入最终镜像 | radare2 安装整体迁至 final 阶段层序尾部（独立层，ARG 在 final 重新声明），builder 段删除，层尾加 `r2 -v && rabin2 -v` 构建期断言 | DinD 构建逐字复刻层：`r2 6.1.6`/`rabin2 6.1.6` 正常输出 |
| 2. anything-analyzer 无法启动 | apt 清单只有 `libfuse2` 库，缺 AppImage runtime 挂载必需的 setuid `fusermount` 助手（fuse2 世代 runtime 硬编码找 `fusermount`，libfuse2 的 `exec_fusermount` ENOENT 即退出） | 大 apt 层补装 `fuse3`（deb 自带 `fusermount → fusermount3` 兼容符号链接，新旧 runtime 通吃），层尾加 fusermount 存在性 + setuid 位断言 | 特权容器端到端：`--appimage-mount` 成功输出 `/tmp/.mount_*`（修复前 exit 127） |
| 3. healthcheck 恒失败 | `supervisorctl status` 遵循 LSB：存在任一非 RUNNING 程序即返回 3，dockerd 设计上 `autostart=false` 恒 STOPPED；`set -e` 在第一条命令即退出，健康断言从未执行 | 捕获 supervisorctl 输出并 `|| true` 吞退出码，健康语义只由三个显式 grep 断言决定；新增 RUNNING 守卫（supervisord 挂掉必失败）；`ENABLE_DOCKERD=1` 时附加 dockerd RUNNING 断言 | 5 场景全过：默认环境 rc=0；ENABLE_DOCKERD=1 / serena FATAL / supervisord 不可达 / sshd 消失均 rc=1 且输出具体原因 |

