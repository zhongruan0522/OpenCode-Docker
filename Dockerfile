# syntax=docker/dockerfile:1

# ==========================================
# 动态层：仅包含自动检测更新的组件
# FROM 基础镜像（ghcr.io/zhongruan0522/opencode-docker:base）
# 每次自动更新触发时只重建此文件，base 层完全复用缓存
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
#   1. Open Design   ← 最重的构建（pnpm install + build + cp 资源），最低频
#   2. code-server   ← apt deb，中低频
#   3. serena-agent  ← uv tool install，中低频
#   4. Codex         ← npm，中频
#   5. Claude Code   ← npm，中高频
#   6. opencode      ← npm，最高频（用户感知最强的小版本迭代）
#
# 反例：早期实现把 opencode 排在 serena/Open Design 之前，
# 导致 opencode 一升级，serena + Open Design 这两个最重的层全部重建
# （实测 1.8.10 → 1.8.14 仅 opencode 小版本升级，用户拉取量 +9G）。
# 拆分 npm 层后，单个 npm 包升级只重建自己一层，不影响其他 npm 包缓存。

ARG BASE_IMAGE=ghcr.io/zhongruan0522/opencode-docker:base
FROM ${BASE_IMAGE}

ARG OPENCODE_VERSION=latest
ARG CODE_SERVER_VERSION=4.115.0
ARG CODEX_VERSION=latest
ARG SERENA_VERSION=latest
ARG CLAUDE_CODE_VERSION=latest
ARG OPEN_DESIGN_VERSION=0.16.1

# === 1. Open Design（最重 + 最低频，必须排最前）===
# 构建 daemon 后端 + web 前端（Next.js 静态导出到 apps/web/out），并复制
# skills/design-systems/craft/prompt-templates 等资源目录。
# 构建依赖（build-essential、python3、make、g++、pnpm）已由 base 镜像提供。
# 单层体积最大，排在最前确保后续任何动态包升级都不会触发它重建。
RUN git clone --depth 1 --branch "open-design-v${OPEN_DESIGN_VERSION}" \
         https://github.com/nexu-io/open-design.git /tmp/open-design \
    && cd /tmp/open-design \
    && pnpm install --frozen-lockfile \
    && pnpm --filter @open-design/daemon build \
    && pnpm --filter @open-design/web build \
    && pnpm --filter @open-design/daemon deploy --legacy --prod /tmp/od-deploy/daemon \
    # 安装产物到 /opt/open-design
    && mkdir -p /opt/open-design/apps/daemon /opt/open-design/apps/web \
    && cp -r /tmp/od-deploy/daemon /opt/open-design/apps/ \
    && cp -r /tmp/open-design/apps/web/out /opt/open-design/apps/web/out \
    && cp -r /tmp/open-design/skills /opt/open-design/skills \
    && cp -r /tmp/open-design/design-systems /opt/open-design/design-systems \
    && cp -r /tmp/open-design/craft /opt/open-design/craft \
    && cp -r /tmp/open-design/prompt-templates /opt/open-design/prompt-templates \
    && mkdir -p /opt/open-design/assets \
    && cp -r /tmp/open-design/assets/frames /opt/open-design/assets/frames \
    && cp -r /tmp/open-design/assets/community-pets /opt/open-design/assets/community-pets \
    # cp -r 不会自动创建中间目录，必须先建 plugins 父目录再复制 _official
    && mkdir -p /opt/open-design/plugins \
    && cp -r /tmp/open-design/plugins/_official /opt/open-design/plugins/_official \
    && mkdir -p /opt/open-design/.od \
    # 清理源码
    && rm -rf /tmp/open-design /tmp/od-deploy

# === 2. code-server（apt deb，中低频）===
RUN CODE_SERVER_ARCH="$(dpkg --print-architecture)" \
    && case "${CODE_SERVER_ARCH}" in amd64|arm64) ;; *) echo "Unsupported code-server architecture: ${CODE_SERVER_ARCH}" >&2; exit 1 ;; esac \
    && curl -fsSLo /tmp/code-server.deb "https://github.com/coder/code-server/releases/download/v${CODE_SERVER_VERSION}/code-server_${CODE_SERVER_VERSION}_${CODE_SERVER_ARCH}.deb" \
    && apt-get update \
    && apt-get install -y /tmp/code-server.deb \
    && rm -f /tmp/code-server.deb \
    && rm -rf /var/lib/apt/lists/*

# === 3. serena-agent（uv tool install，中低频）===
RUN if ! command -v uv >/dev/null 2>&1; then \
      curl -fsSL https://astral.sh/uv/install.sh | env CARGO_HOME=/tmp/uv-cargo UV_INSTALL_DIR=/usr/local/bin sh \
      && rm -rf /tmp/uv-cargo; \
    fi \
    && UV_TOOL_BIN_DIR=/usr/local/bin uv tool install -p 3.13 "serena-agent@${SERENA_VERSION}" --prerelease=allow \
    && serena init

# === 4. Codex（npm，中频）===
# 拆分独立层：单个 npm 包升级不再连带重建其他 npm 包。
RUN npm install -g @openai/codex@${CODEX_VERSION}

# === 5. Claude Code（npm，中高频）===
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

# === 6. opencode（最高频，必须排最后）===
# rm -rf 必须与 install 在同一 RUN 内：Docker 层叠加，
# 在新层里删除上一层添加的文件不会回收空间，必须安装+删除在同一层完成。
RUN npm install -g opencode-ai@${OPENCODE_VERSION} \
    && rm -rf /usr/local/lib/node_modules/opencode-ai/node_modules/opencode-linux-x64-baseline \
              /usr/local/lib/node_modules/opencode-ai/node_modules/opencode-linux-x64-baseline-musl \
              /usr/local/lib/node_modules/opencode-ai/node_modules/opencode-linux-x64-musl

# 动态层覆盖启动配置。
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY docker/healthcheck.sh /usr/local/bin/healthcheck.sh
COPY docker/supervisord.conf /etc/supervisor/supervisord.conf
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh
