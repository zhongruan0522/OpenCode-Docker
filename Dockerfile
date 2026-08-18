# syntax=docker/dockerfile:1

# ==========================================
# 动态层：仅包含自动检测更新的组件
# FROM 桌面层镜像（ghcr.io/zhongruan0522/opencode-docker:desktop）
# 每次自动更新触发时只重建此文件，Base/桌面层完全复用缓存
# ==========================================

# ---
# 层排序策略（重要！修改顺序前请务必阅读）
# ---
# Docker 缓存 key = 父层 digest + 当前层命令字符串（含 ARG 替换值）。
# 任意一层重建都会让其下游所有层失效——即使下游命令完全没变，
# 由于父层 digest 变了，下游也必须重新执行，并产生新的层 digest。
# 因此层顺序必须严格按「更新频率从低到高」排列：
#   最稳定（最重、最低频）→ 最易变（最轻、最高频）
# 这样高频包升级时，低频/重型层才能命中缓存不重建。
#
# 当前顺序（自上而下，父→子）：
#   1. code-server   ← apt deb，中低频
#   2. serena-agent  ← uv tool install，中低频
#   3. Codex         ← npm，中频
#   4. Claude Code   ← npm，中高频
#   4.5 CC 补丁       ← agent/ccpatch/*.sh，中低频（紧跟 CC 层，CC 升级时自动对最新 cli.js 重跑）
#   5. codex-security ← npm，高频（0.x 早期阶段，迭代极快）
#   6. opencode      ← npm，最高频（用户感知最强的小版本迭代）
#
# 拆分 npm 层后，单个 npm 包升级只重建自己一层，不影响其他 npm 包缓存。

ARG BASE_IMAGE=ghcr.io/zhongruan0522/opencode-docker:desktop
FROM ${BASE_IMAGE}

ARG OPENCODE_VERSION=latest
ARG CODE_SERVER_VERSION=4.115.0
ARG CODEX_VERSION=latest
ARG SERENA_VERSION=latest
ARG CLAUDE_CODE_VERSION=latest
ARG CODEX_SECURITY_VERSION=latest

# === 1. code-server（apt deb，中低频）===
RUN CODE_SERVER_ARCH="$(dpkg --print-architecture)" \
    && case "${CODE_SERVER_ARCH}" in amd64|arm64) ;; *) echo "Unsupported code-server architecture: ${CODE_SERVER_ARCH}" >&2; exit 1 ;; esac \
    && curl -fsSLo /tmp/code-server.deb "https://github.com/coder/code-server/releases/download/v${CODE_SERVER_VERSION}/code-server_${CODE_SERVER_VERSION}_${CODE_SERVER_ARCH}.deb" \
    && apt-get update \
    && apt-get install -y /tmp/code-server.deb \
    && rm -f /tmp/code-server.deb \
    && rm -rf /var/lib/apt/lists/*

# === 2. serena-agent（uv tool install，中低频）===
RUN if ! command -v uv >/dev/null 2>&1; then \
      curl -fsSL https://astral.sh/uv/install.sh | env CARGO_HOME=/tmp/uv-cargo UV_INSTALL_DIR=/usr/local/bin sh \
      && rm -rf /tmp/uv-cargo; \
    fi \
    && UV_TOOL_BIN_DIR=/usr/local/bin uv tool install -p 3.13 "serena-agent@${SERENA_VERSION}" --prerelease=allow \
    && serena init

# === 3. Codex（npm，中频）===
# 拆分独立层：单个 npm 包升级不再连带重建其他 npm 包。
RUN npm install -g @openai/codex@${CODEX_VERSION}

# === 4. Claude Code（npm，中高频）===
# 动态层不再安装原版 @anthropic-ai/claude-code，改用社区 fork @cometix/claude-code。
# 版本由 CLAUDE_CODE_VERSION 驱动（check-update.yml 检测 CometixSpace/claude-code 的 GitHub releases）。
# @cometix/ccline 是配套工具，随 CC 一起重建，不单独接入自动更新。
RUN npm install -g @cometix/claude-code@${CLAUDE_CODE_VERSION} \
    && npm install -g @cometix/ccline

# === 4.5 Claude Code 补丁（agent/ccpatch/，中低频）===
# 装完 Claude Code 后自动执行 agent/ccpatch/ 下全部 *.sh 补丁脚本。
# - 兼容性：runner 用 glob 遍历，未来新增 .sh 无需改 Dockerfile 自动生效。
# - 容错：任一脚本失败仅告警不中断（runner 内部容错 + 外层 || true 双保险），构建不受影响。
# - 层排序：紧跟 CC 层之后——CC 升级 → 父层 digest 变化 → 此层对最新 cli.js 自动重跑补丁。
COPY agent/run-ccpatch.sh /usr/local/bin/run-ccpatch.sh
COPY agent/ccpatch/ /opt/ccpatch/
RUN chmod +x /usr/local/bin/run-ccpatch.sh \
    && /usr/local/bin/run-ccpatch.sh || true

# === 5. codex-security（npm，高频）===
# OpenAI Codex Security CLI，仅 npm 分发：https://www.npmjs.com/package/@openai/codex-security
RUN npm install -g @openai/codex-security@${CODEX_SECURITY_VERSION}

# === 6. opencode（最高频，必须排最后）===
# rm -rf 必须与 install 在同一 RUN 内：Docker 层叠加，
# 在新层里删除上一层添加的文件不会回收空间，必须安装+删除在同一层完成。
RUN npm install -g opencode-ai@${OPENCODE_VERSION} \
    && rm -rf /usr/local/lib/node_modules/opencode-ai/node_modules/opencode-linux-x64-baseline \
              /usr/local/lib/node_modules/opencode-ai/node_modules/opencode-linux-x64-baseline-musl \
              /usr/local/lib/node_modules/opencode-ai/node_modules/opencode-linux-x64-musl

# 动态层覆盖启动配置。
COPY base/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY base/healthcheck.sh /usr/local/bin/healthcheck.sh
COPY base/supervisord.conf /etc/supervisor/supervisord.conf
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh
