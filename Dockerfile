# syntax=docker/dockerfile:1

# ==========================================
# 动态层：仅包含自动检测更新的组件
# FROM 基础镜像（ghcr.io/zhongruan0522/opencode-docker:base）
# 每次自动更新触发时只重建此文件，base 层完全复用缓存
# ==========================================

ARG BASE_IMAGE=ghcr.io/zhongruan0522/opencode-docker:base
FROM ${BASE_IMAGE}

ARG OPENCODE_VERSION=latest
ARG CODEX_VERSION=latest

# npm 全局包（自动更新检测的组件）
RUN --mount=type=cache,target=/root/.npm \
    npm install -g opencode-ai@${OPENCODE_VERSION} \
    && npm install -g @openai/codex@${CODEX_VERSION} \
    && npm install -g @z_ai/mcp-server@0.1.3 @larksuite/cli \
    && rm -rf /usr/local/lib/node_modules/opencode-ai/node_modules/opencode-linux-x64-baseline \
              /usr/local/lib/node_modules/opencode-ai/node_modules/opencode-linux-x64-baseline-musl \
              /usr/local/lib/node_modules/opencode-ai/node_modules/opencode-linux-x64-musl
