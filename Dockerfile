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
ARG CLAUDE_CODE_VERSION=latest
ARG CYBERSTRIKE_VERSION=latest

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
    && npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} \
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

# CyberStrikeAI（自动更新检测，源码 clone + go build）
# Go 项目，运行时只需编译后的二进制 + web 静态资源。
# 版本号 latest 时取最新 release tag，否则使用指定 tag（不带 v 前缀）。
RUN CS_TAG="${CYBERSTRIKE_VERSION}" \
    && if [ "${CS_TAG}" = "latest" ] || [ -z "${CS_TAG}" ]; then \
         CS_TAG="$(curl -fsSL https://api.github.com/repos/Ed1s0nZ/CyberStrikeAI/releases/latest | jq -r '.tag_name')"; \
       fi \
    && echo "CyberStrikeAI version: ${CS_TAG}" \
    && mkdir -p /opt/cyberstrike-ai \
    && curl -fsSL "https://github.com/Ed1s0nZ/CyberStrikeAI/archive/refs/tags/${CS_TAG}.tar.gz" \
       | tar -xz -C /opt/cyberstrike-ai --strip-components=1 \
    && cd /opt/cyberstrike-ai \
    && go mod download \
    && CGO_ENABLED=1 go build -o cyberstrike-ai cmd/server/main.go \
    # 清理编译产物和不需要运行时保留的源码目录，保留二进制 + web/ + 默认配置/角色/技能/工具模板
    && rm -rf cmd internal docs images .git *.md LICENSE go.mod go.sum requirements.txt run.sh upgrade.sh \
    && chmod +x /opt/cyberstrike-ai/cyberstrike-ai

# 动态层覆盖启动配置。
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY docker/healthcheck.sh /usr/local/bin/healthcheck.sh
COPY docker/supervisord.conf /etc/supervisor/supervisord.conf
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh
