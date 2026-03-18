FROM node:22-bookworm-slim

ARG DEBIAN_FRONTEND=noninteractive
USER root
WORKDIR /app

ENV GOLANG_VERSION=1.22.0

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
        nano \
        tmux \
    && sed -i 's/# zh_CN.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/' /etc/locale.gen \
    && locale-gen \
    && curl -fsSL https://go.dev/dl/go${GOLANG_VERSION}.linux-$(dpkg --print-architecture).tar.gz | tar -C /usr/local -xzf - \
    && rm -rf /var/lib/apt/lists/*

ENV PATH="/usr/local/go/bin:${PATH}" \
    GOPATH="/home/app/go"

RUN npm install -g npm@latest \
    && npm install -g opencode-ai \
    && npx @playwright/mcp@latest install --with-deps chromium \
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

RUN cp -r /root/.cache/ms-playwright /home/app/.cache/ms-playwright \
    && chown -R app:app /home/app/.cache/ms-playwright \
    && rm -rf /root/.cache/ms-playwright

COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /workspace

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
