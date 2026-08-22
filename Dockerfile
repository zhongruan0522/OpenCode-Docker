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
#   6. Antigravity    ← 官方清单最新版二进制直装，高频（1.x 早期阶段）
#   7. opencode       ← npm，最高频（用户感知最强的小版本迭代）
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
ARG ANTIGRAVITY_VERSION=latest

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

# === 6. Antigravity CLI（agy，官方清单直装，高频）===
# 安装流程等价官方 bootstrapper（curl -fsSL https://antigravity.google/cli/install.sh | bash）：
# 清单 → 下载 → SHA512 校验 → 落盘 /usr/local/bin/agy。三点与 npm 组件不同：
# - 无历史版本可锁：manifests/linux_amd64.json 永远只返回最新版（version/url/sha512），
#   因此 ARG 仅作缓存 key（CI 每次构建前实时查清单传入），使 agy 自身升级能失效本层；
#   构建期若清单已比 ARG 新，说明上游在构建间隙发了新版——告警后照装最新版
#   （清单装不了旧版，严格报错会拖垮所有底层级联重建；元数据漂移由下轮 check-update 自愈）。
# - GCS 下载链路实测存在 403/200 交替抖动（与 UA 无关），必须 --retry-all-errors 才能稳定下载。
# - 包内是单个二进制 antigravity（解压后约 197MB），安装+清理必须同一 RUN 完成以回收空间。
RUN set -eux \
    && AGY_ARCH="$(dpkg --print-architecture)" \
    && case "${AGY_ARCH}" in amd64|arm64) ;; *) echo "Unsupported Antigravity CLI architecture: ${AGY_ARCH}" >&2; exit 1 ;; esac \
    && curl -fsSL --retry 10 --retry-all-errors --retry-delay 2 -o /tmp/agy-manifest.json \
        "https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/linux_${AGY_ARCH}.json" \
    && AGY_LATEST="$(jq -r '.version' /tmp/agy-manifest.json)" \
    && AGY_URL="$(jq -r '.url' /tmp/agy-manifest.json)" \
    && AGY_SHA512="$(jq -r '.sha512' /tmp/agy-manifest.json)" \
    && if [ -z "${AGY_LATEST}" ] || [ -z "${AGY_URL}" ] || [ -z "${AGY_SHA512}" ]; then \
        echo "Malformed Antigravity CLI manifest" >&2; exit 1; fi \
    && if [ "${ANTIGRAVITY_VERSION}" != "latest" ] && [ "${ANTIGRAVITY_VERSION}" != "${AGY_LATEST}" ]; then \
        echo "WARNING: requested Antigravity CLI ${ANTIGRAVITY_VERSION}, but upstream manifest serves ${AGY_LATEST}; installing ${AGY_LATEST}" >&2; fi \
    && curl -fsSL --retry 10 --retry-all-errors --retry-delay 2 -o /tmp/agy.tar.gz "${AGY_URL}" \
    && echo "${AGY_SHA512}  /tmp/agy.tar.gz" | sha512sum -c - \
    && tar -xzf /tmp/agy.tar.gz -C /tmp \
    && install -m 0755 /tmp/antigravity /usr/local/bin/agy \
    && /usr/local/bin/agy --version \
    && rm -rf /tmp/agy-manifest.json /tmp/agy.tar.gz /tmp/antigravity

# === 7. opencode（最高频，必须排最后）===
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
