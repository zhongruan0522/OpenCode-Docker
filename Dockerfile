# syntax=docker/dockerfile:1

# ==========================================
# 阶段 1：编译 MicroSOCKS 引擎 (基于 MicroWARP)
# ==========================================
FROM alpine:latest AS microsocks-builder

RUN apk add --no-cache build-base git
# 静态编译 microsocks，避免 musl 动态链接在 Debian glibc 环境下无法运行
RUN git clone https://github.com/rofl0r/microsocks.git /src && \
    cd /src && make CFLAGS="-static -O2" LDFLAGS="-static"

# ==========================================
# 阶段 2：构建环境（完整工具链，产出所有制品）
# ==========================================
FROM node:24-bookworm-slim AS builder

ARG DEBIAN_FRONTEND=noninteractive
ARG OPENCODE_VERSION=latest
ARG CODE_SERVER_VERSION=4.115.0
ARG CODEX_VERSION=latest
ARG PLAYWRIGHT_MCP_VERSION=0.0.70

ENV GOLANG_VERSION=1.26.1
ENV ANDROID_SDK_ROOT=/opt/android-sdk
ENV PLAYWRIGHT_BROWSERS_PATH=/home/app/.cache/ms-playwright \
    BUN_INSTALL=/opt/bun
ENV PATH="/usr/local/go/bin:/opt/bun/bin:${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin:${ANDROID_SDK_ROOT}/platform-tools:${PATH}"

# 系统依赖（含 build-essential，构建完就扔）
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        locales \
        ca-certificates \
        curl \
        gnupg \
        git \
        bash \
        gosu \
        supervisor \
        openssh-client \
        python3 \
        python3-pip \
        python3-venv \
        build-essential \
        openjdk-17-jdk-headless \
        vim \
        wget \
        unzip \
        nano \
        tmux \
        ripgrep \
        sqlite3 \
        libsqlite3-dev \
        python-is-python3 \
        poppler-utils \
        fonts-noto-cjk \
        bubblewrap \
        wireguard-tools \
        iptables \
        iproute2 \
        kmod \
    && sed -i 's/# zh_CN.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/' /etc/locale.gen \
    && locale-gen \
    && rm -rf /var/lib/apt/lists/*

# Go + Bun（仅清理文档/测试等非运行必需文件，保留 src 和 pkg/linux_amd64 以确保编译可用）
RUN curl -fsSL https://go.dev/dl/go${GOLANG_VERSION}.linux-$(dpkg --print-architecture).tar.gz | tar -C /usr/local -xzf - \
    && curl -fsSL https://bun.sh/install | bash \
    && ln -sf /opt/bun/bin/bun /usr/local/bin/bun \
    && rm -rf /usr/local/go/test /usr/local/go/doc /usr/local/go/misc /usr/local/go/api

# Android SDK（command-line tools + build-tools + platform-tools + platforms + Gradle）
RUN mkdir -p "${ANDROID_SDK_ROOT}/cmdline-tools" \
    && curl -fsSL "https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip" -o /tmp/cmdline-tools.zip \
    && unzip -q /tmp/cmdline-tools.zip -d /tmp/cmdline-tools \
    && mv /tmp/cmdline-tools/cmdline-tools "${ANDROID_SDK_ROOT}/cmdline-tools/latest" \
    && rm -rf /tmp/cmdline-tools.zip /tmp/cmdline-tools \
    && yes | sdkmanager --licenses > /dev/null 2>&1 \
    && sdkmanager --install \
        "build-tools;35.0.1" \
        "build-tools;30.0.2" \
        "platform-tools" \
        "platforms;android-35" \
        "platforms;android-34" \
        "platforms;android-30" \
    && rm -rf "${ANDROID_SDK_ROOT}/.temp"

# Gradle 7.5 + 9.0
ENV GRADLE_HOME=/opt/gradle
RUN curl -fsSL "https://services.gradle.org/distributions/gradle-7.5-bin.zip" -o /tmp/gradle-7.5.zip \
    && unzip -q /tmp/gradle-7.5.zip -d /opt \
    && curl -fsSL "https://services.gradle.org/distributions/gradle-9.0-bin.zip" -o /tmp/gradle-9.0.zip \
    && unzip -q /tmp/gradle-9.0.zip -d /opt \
    && ln -sf /opt/gradle-9.0.0/bin/gradle /usr/local/bin/gradle \
    && rm -f /tmp/gradle-7.5.zip /tmp/gradle-9.0.zip

# microsocks
COPY --from=microsocks-builder /src/microsocks /usr/local/bin/microsocks

# code-server + gh CLI（极少变动，稳定缓存）
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && CODE_SERVER_ARCH="$(dpkg --print-architecture)" \
    && case "${CODE_SERVER_ARCH}" in amd64|arm64) ;; *) echo "Unsupported code-server architecture: ${CODE_SERVER_ARCH}" >&2; exit 1 ;; esac \
    && curl -fsSLo /tmp/code-server.deb "https://github.com/coder/code-server/releases/download/v${CODE_SERVER_VERSION}/code-server_${CODE_SERVER_VERSION}_${CODE_SERVER_ARCH}.deb" \
    && apt-get update \
    && apt-get install -y /tmp/code-server.deb gh \
    && rm -f /tmp/code-server.deb \
    && rm -rf /var/lib/apt/lists/*

# npm 全局包（cache mount 只缓存下载，不干扰版本解析）
RUN --mount=type=cache,target=/root/.npm \
    npm install -g opencode-ai@${OPENCODE_VERSION} \
    && PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm install -g @playwright/mcp@${PLAYWRIGHT_MCP_VERSION} \
    && npm install -g @z_ai/mcp-server@0.1.3 @larksuite/cli @openai/codex@${CODEX_VERSION} \
    && rm -rf /usr/local/lib/node_modules/opencode-ai/node_modules/opencode-linux-x64-baseline \
              /usr/local/lib/node_modules/opencode-ai/node_modules/opencode-linux-x64-baseline-musl \
              /usr/local/lib/node_modules/opencode-ai/node_modules/opencode-linux-x64-musl

# Python 包（cache mount 加速 pip 下载）
RUN --mount=type=cache,target=/root/.cache/pip \
    python3 -m pip install --no-cache-dir --break-system-packages \
        Pillow \
        "scrapling[all]>=0.4.2"

# Playwright Chromium 浏览器（体积大头，单独一层）
RUN mkdir -p "${PLAYWRIGHT_BROWSERS_PATH}" \
    && PLAYWRIGHT_ROOT="$(npm root -g)" \
    && if [ -f "${PLAYWRIGHT_ROOT}/@playwright/mcp/node_modules/playwright/cli.js" ]; then \
         PLAYWRIGHT_CLI="${PLAYWRIGHT_ROOT}/@playwright/mcp/node_modules/playwright/cli.js"; \
       elif [ -f "${PLAYWRIGHT_ROOT}/playwright/cli.js" ]; then \
         PLAYWRIGHT_CLI="${PLAYWRIGHT_ROOT}/playwright/cli.js"; \
       elif [ -f "${PLAYWRIGHT_ROOT}/@playwright/mcp/node_modules/playwright-core/cli.js" ]; then \
         PLAYWRIGHT_CLI="${PLAYWRIGHT_ROOT}/@playwright/mcp/node_modules/playwright-core/cli.js"; \
       else \
         echo "Playwright CLI not found in ${PLAYWRIGHT_ROOT}" >&2; \
         exit 1; \
       fi \
    && PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH}" node "${PLAYWRIGHT_CLI}" install --with-deps chromium \
    && PYTHON_PW_REVISION=$(python3 -m playwright install --dry-run chromium 2>&1 | grep -oP 'chromium v\K[0-9]+') \
    && NODE_REVISION=$(ls -d "${PLAYWRIGHT_BROWSERS_PATH}/chromium-"* | grep -oP 'chromium-\K[0-9]+' | sort -rn | head -1) \
    && if [ "${PYTHON_PW_REVISION}" != "${NODE_REVISION}" ]; then \
         echo "Symlinking chromium-${PYTHON_PW_REVISION} -> chromium-${NODE_REVISION} for Python playwright"; \
         ln -sf "${PLAYWRIGHT_BROWSERS_PATH}/chromium-${NODE_REVISION}" "${PLAYWRIGHT_BROWSERS_PATH}/chromium-${PYTHON_PW_REVISION}"; \
         if [ -d "${PLAYWRIGHT_BROWSERS_PATH}/chromium_headless_shell-${NODE_REVISION}" ]; then \
           ln -sf "${PLAYWRIGHT_BROWSERS_PATH}/chromium_headless_shell-${NODE_REVISION}" "${PLAYWRIGHT_BROWSERS_PATH}/chromium_headless_shell-${PYTHON_PW_REVISION}"; \
         fi; \
       else \
         echo "Revisions match (${NODE_REVISION}), no symlink needed"; \
       fi \
    && scrapling install --force

# ==========================================
# 阶段 3：最终运行镜像（无编译工具链，从 builder 拷成品）
# ==========================================
FROM node:24-bookworm-slim

ARG DEBIAN_FRONTEND=noninteractive
USER root
WORKDIR /app

# 运行时依赖（含 gcc 以支持 CGO）+ Playwright Chromium 系统库
# 注：builder 阶段 `playwright install --with-deps` 只在 builder 层安装了这些库，
# multi-stage COPY 不会带走 apt 安装的系统包，必须在 final 阶段显式声明。
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        locales \
        ca-certificates \
        curl \
        gnupg \
        git \
        bash \
        gosu \
        supervisor \
        openssh-client \
        python3 \
        python3-pip \
        python3-venv \
        tini \
        vim \
        wget \
        unzip \
        nano \
        tmux \
        ripgrep \
        sqlite3 \
        libsqlite3-dev \
        python-is-python3 \
        poppler-utils \
        fonts-noto-cjk \
        bubblewrap \
        wireguard-tools \
        iptables \
        iproute2 \
        kmod \
        gcc \
        openjdk-17-jdk-headless \
        libnss3 \
        libnspr4 \
        libatk1.0-0 \
        libatk-bridge2.0-0 \
        libcups2 \
        libdrm2 \
        libgbm1 \
        libxkbcommon0 \
        libxcomposite1 \
        libxdamage1 \
        libxfixes3 \
        libxrandr2 \
        libasound2 \
        libatspi2.0-0 \
        libpango-1.0-0 \
        libcairo2 \
        libdbus-1-3 \
    && sed -i 's/# zh_CN.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/' /etc/locale.gen \
    && locale-gen \
    && rm -rf /var/lib/apt/lists/*

# Docker CE（DinD 模式：容器内运行独立 dockerd，重启即复原）
RUN curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker.gpg] https://download.docker.com/linux/debian bookworm stable" \
       > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce docker-ce-cli docker-compose-plugin iptables \
    && rm -rf /var/lib/apt/lists/*

# 创建架构无关的 JAVA_HOME 符号链接
RUN JAVA_REAL_HOME="$(dirname "$(dirname "$(readlink -f "$(which javac)")")")" \
    && ln -sf "${JAVA_REAL_HOME}" /usr/lib/jvm/java-17-openjdk-current

# 从 builder 复制所有构建产物
# /usr/local 包含：Go SDK、npm 全局包、pip 安装包、全局二进制 symlink
COPY --from=builder /usr/local /usr/local
# Bun 运行环境
COPY --from=builder /opt /opt
# code-server + gh
COPY --from=builder /usr/lib/code-server /usr/lib/code-server
COPY --from=builder /usr/bin/code-server /usr/bin/code-server
COPY --from=builder /usr/bin/gh /usr/bin/gh
# Playwright Chromium 浏览器
COPY --from=builder /home/app/.cache/ms-playwright /home/app/.cache/ms-playwright

ENV JAVA_HOME=/usr/lib/jvm/java-17-openjdk-current \
    ANDROID_SDK_ROOT=/opt/android-sdk

ENV PATH="/usr/local/go/bin:/home/app/go/bin:/opt/bun/bin:/opt/gradle-9.0.0/bin:/opt/gradle-7.5/bin:/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools:/usr/lib/jvm/java-17-openjdk-current/bin:${PATH}" \
    GOPATH="/home/app/go" \
    BUN_INSTALL="/opt/bun" \
    PLAYWRIGHT_BROWSERS_PATH=/home/app/.cache/ms-playwright \
    PLAYWRIGHT_MCP_HEADLESS=1 \
    PLAYWRIGHT_MCP_BROWSER=chromium \
    PLAYWRIGHT_MCP_NO_SANDBOX=1 \
    WARP_SOCKS_PORT=1080 \
    LANG=zh_CN.UTF-8 \
    LANGUAGE=zh_CN:zh \
    LC_ALL=zh_CN.UTF-8 \
    EDITOR=vim \
    PIP_BREAK_SYSTEM_PACKAGES=1 \
    HOME=/home/app

# 用户和目录
RUN if ! id -u app >/dev/null 2>&1; then useradd --create-home --shell /bin/bash --uid 10001 app; fi \
    && mkdir -p /workspace /home/app/.config/opencode /home/app/.config/code-server \
               /home/app/.cache /home/app/.local/share/code-server /etc/wireguard \
    && chown -R app:app /home/app /workspace "${PLAYWRIGHT_BROWSERS_PATH}"

COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY docker/healthcheck.sh /usr/local/bin/healthcheck.sh
COPY docker/supervisord.conf /etc/supervisor/supervisord.conf
COPY docker/microwarp/init-warp.sh /usr/local/bin/init-warp.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh /usr/local/bin/init-warp.sh

WORKDIR /workspace

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD /usr/local/bin/healthcheck.sh

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
