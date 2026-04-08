FROM node:22-bookworm-slim

ARG DEBIAN_FRONTEND=noninteractive
ARG OPENCODE_VERSION=latest
USER root
WORKDIR /app

ENV GOLANG_VERSION=1.26.1

# Install Bun into /opt/bun instead of /root/.bun. Because the installer runs
# through a pipe, BUN_INSTALL must be exported before invoking bash.

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        locales \
        ca-certificates \
        curl \
        gnupg \
        git \
        bash \
        gosu \
        openssh-client \
        python3 \
        python3-pip \
        python3-venv \
        build-essential \
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
        pandoc \
        poppler-utils \
        libreoffice \
        fonts-noto-cjk \
    && sed -i 's/# zh_CN.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/' /etc/locale.gen \
    && locale-gen \
    && curl -fsSL https://go.dev/dl/go${GOLANG_VERSION}.linux-$(dpkg --print-architecture).tar.gz | tar -C /usr/local -xzf - \
    && export BUN_INSTALL=/opt/bun \
    && curl -fsSL https://bun.sh/install | bash \
    && ln -sf /opt/bun/bin/bun /usr/local/bin/bun \
    && rm -rf /var/lib/apt/lists/*

ENV PATH="/usr/local/go/bin:/opt/bun/bin:${PATH}" \
    GOPATH="/home/app/go" \
    BUN_INSTALL="/opt/bun"

# Playwright MCP is a Node tool; install it in the image so OpenCode can start
# the browser MCP without downloading packages at runtime.
#
# NOTE: @playwright/mcp pins a specific (often alpha) Playwright version.
# We install Chromium using that exact Playwright dependency to avoid revision
# mismatches like "Executable doesn't exist" at runtime.
# Office/document skills and scraping skills also depend on additional npm and
# Python packages, so install them here to keep fresh images usable out of the box.
ARG PLAYWRIGHT_MCP_VERSION=0.0.70

# Keep browsers in a shared path owned by the non-root user at runtime.
# Also default Playwright MCP to a container-friendly mode.
ENV PLAYWRIGHT_BROWSERS_PATH=/home/app/.cache/ms-playwright \
    PLAYWRIGHT_MCP_HEADLESS=1 \
    PLAYWRIGHT_MCP_BROWSER=chromium \
    PLAYWRIGHT_MCP_NO_SANDBOX=1

RUN npm install -g opencode-ai@${OPENCODE_VERSION} \
    && PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm install -g @playwright/mcp@${PLAYWRIGHT_MCP_VERSION} \
    && npm install -g docx pptxgenjs zread_cli \
    && python3 -m pip install --no-cache-dir --break-system-packages \
         "markitdown[pptx]" \
         openpyxl \
         pandas \
         Pillow \
         "scrapling[all]>=0.4.2" \
    && mkdir -p "${PLAYWRIGHT_BROWSERS_PATH}" \
    # Install chromium via Node MCP's playwright (revision 1217 = Chrome 147)
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
    # Detect the installed revision and symlink it for Python playwright compatibility.
    # Node MCP uses alpha playwright (currently revision 1217), while Python playwright
    # stable looks for revision 1208. Symlinking avoids downloading a second copy (~600MB).
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
    && scrapling install --force \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update && apt-get install -y gh && rm -rf /var/lib/apt/lists/*

ENV LANG=zh_CN.UTF-8 \
    LANGUAGE=zh_CN:zh \
    LC_ALL=zh_CN.UTF-8 \
    EDITOR=vim \
    PIP_BREAK_SYSTEM_PACKAGES=1 \
    HOME=/home/app

RUN if ! id -u app >/dev/null 2>&1; then useradd --create-home --shell /bin/bash --uid 10001 app; fi \
    && mkdir -p /workspace /home/app/.config/opencode /home/app/.cache \
    && chown -R app:app /home/app /workspace

RUN chown -R app:app "${PLAYWRIGHT_BROWSERS_PATH}"

COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /workspace

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
