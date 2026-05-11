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

# code-server（自动更新检测）
RUN CODE_SERVER_ARCH="$(dpkg --print-architecture)" \
    && case "${CODE_SERVER_ARCH}" in amd64|arm64) ;; *) echo "Unsupported code-server architecture: ${CODE_SERVER_ARCH}" >&2; exit 1 ;; esac \
    && curl -fsSLo /tmp/code-server.deb "https://github.com/coder/code-server/releases/download/v${CODE_SERVER_VERSION}/code-server_${CODE_SERVER_VERSION}_${CODE_SERVER_ARCH}.deb" \
    && apt-get update \
    && apt-get install -y /tmp/code-server.deb \
    && rm -f /tmp/code-server.deb \
    && rm -rf /var/lib/apt/lists/*

# npm 全局包（自动更新检测的组件）
ARG WRANGLER_VERSION=latest

RUN --mount=type=cache,target=/root/.npm \
    npm install -g opencode-ai@${OPENCODE_VERSION} \
    && npm install -g @openai/codex@${CODEX_VERSION} \
    && npm install -g wrangler@${WRANGLER_VERSION} \
    && rm -rf /usr/local/lib/node_modules/opencode-ai/node_modules/opencode-linux-x64-baseline \
              /usr/local/lib/node_modules/opencode-ai/node_modules/opencode-linux-x64-baseline-musl \
              /usr/local/lib/node_modules/opencode-ai/node_modules/opencode-linux-x64-musl
