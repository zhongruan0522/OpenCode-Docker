# syntax=docker/dockerfile:1

# ==========================================
# 动态层：仅包含自动检测更新的组件
# FROM 基础镜像（ghcr.io/zhongruan0522/opencode-docker:base）
# 每次自动更新触发时只重建此文件，base 层完全复用缓存
# ==========================================

ARG BASE_IMAGE=ghcr.io/zhongruan0522/opencode-docker:base
FROM ${BASE_IMAGE}

ARG OPENCODE_VERSION=latest
ARG CODE_SERVER_VERSION=4.115.0
ARG CODEX_VERSION=latest
ARG SERENA_VERSION=latest
ARG OPEN_DESIGN_VERSION=0.9.0

# code-server（自动更新检测）
RUN CODE_SERVER_ARCH="$(dpkg --print-architecture)" \
    && case "${CODE_SERVER_ARCH}" in amd64|arm64) ;; *) echo "Unsupported code-server architecture: ${CODE_SERVER_ARCH}" >&2; exit 1 ;; esac \
    && curl -fsSLo /tmp/code-server.deb "https://github.com/coder/code-server/releases/download/v${CODE_SERVER_VERSION}/code-server_${CODE_SERVER_VERSION}_${CODE_SERVER_ARCH}.deb" \
    && apt-get update \
    && apt-get install -y /tmp/code-server.deb \
    && rm -f /tmp/code-server.deb \
    && rm -rf /var/lib/apt/lists/*

# npm 全局包（自动更新检测的组件）
RUN npm install -g opencode-ai@${OPENCODE_VERSION} \
    && npm install -g @openai/codex@${CODEX_VERSION} \
    && rm -rf /usr/local/lib/node_modules/opencode-ai/node_modules/opencode-linux-x64-baseline \
              /usr/local/lib/node_modules/opencode-ai/node_modules/opencode-linux-x64-baseline-musl \
              /usr/local/lib/node_modules/opencode-ai/node_modules/opencode-linux-x64-musl

# serena-agent（自动更新检测，通过 uv tool 安装）
RUN if ! command -v uv >/dev/null 2>&1; then \
      curl -fsSL https://astral.sh/uv/install.sh | env CARGO_HOME=/tmp/uv-cargo UV_INSTALL_DIR=/usr/local/bin sh \
      && rm -rf /tmp/uv-cargo; \
    fi \
    && UV_TOOL_BIN_DIR=/usr/local/bin uv tool install -p 3.13 "serena-agent@${SERENA_VERSION}" --prerelease=allow \
    && serena init

# Open Design（自动更新检测，从源码 clone + build）
# 构建 daemon 后端 + web 前端，并复制 skills/design-systems 等资源目录。
# 需要 build-essential（better-sqlite3 native 编译），构建完成后清理。
RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential python3 make g++ \
    && rm -rf /var/lib/apt/lists/* \
    && git clone --depth 1 --branch "open-design-v${OPEN_DESIGN_VERSION}" \
         https://github.com/nexu-io/open-design.git /tmp/open-design \
    && cd /tmp/open-design \
    && corepack enable \
    && corepack prepare pnpm@10.33.2 --activate \
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
    && mkdir -p /opt/open-design/plugins \
    && cp -r /tmp/open-design/plugins/_official /opt/open-design/plugins/_official \
    # 清理构建依赖和源码
    && apt-get purge -y build-essential python3 make g++ \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/* /tmp/open-design /tmp/od-deploy \
    && mkdir -p /opt/open-design/.od

# 动态层覆盖启动配置。
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY docker/healthcheck.sh /usr/local/bin/healthcheck.sh
COPY docker/supervisord.conf /etc/supervisor/supervisord.conf
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh
