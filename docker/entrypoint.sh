#!/bin/bash
set -e

# 三个认证凭据必须全部设置，否则退出。
MISSING=""
[ -z "${CODE_SERVER_PASSWORD:-}" ] && MISSING="CODE_SERVER_PASSWORD $MISSING"
[ -z "${OPENCODE_SERVER_USERNAME:-}" ] && MISSING="OPENCODE_SERVER_USERNAME $MISSING"
[ -z "${OPENCODE_SERVER_PASSWORD:-}" ] && MISSING="OPENCODE_SERVER_PASSWORD $MISSING"
if [ -n "$MISSING" ]; then
    echo "Error: Missing required environment variables: $MISSING" >&2
    echo "Container will exit." >&2
    exit 1
fi

# code-server 认证：优先使用哈希密码，其次明文密码。
if [ -n "${CODE_SERVER_HASHED_PASSWORD:-}" ]; then
    export HASHED_PASSWORD="${CODE_SERVER_HASHED_PASSWORD}"
    unset PASSWORD
    echo "code-server will use HASHED_PASSWORD authentication."
elif [ -n "${CODE_SERVER_PASSWORD:-}" ]; then
    export PASSWORD="${CODE_SERVER_PASSWORD}"
    unset HASHED_PASSWORD
    echo "code-server will use PASSWORD authentication."
else
    echo "Warning: CODE_SERVER_PASSWORD is not set. code-server will run without authentication." >&2
fi

# ==========================================
# MicroWARP 初始化（可选，通过 ENABLE_WARP=1 开启）
# ==========================================
if [ "${ENABLE_WARP:-0}" = "1" ]; then
    WARP_SOCKS_PORT="${WARP_SOCKS_PORT:-1080}"
    /usr/local/bin/init-warp.sh

    export SOCKS5_PROXY="socks5://127.0.0.1:${WARP_SOCKS_PORT}"
    echo "==> [WARP] 环境变量已注入: SOCKS5_PROXY=${SOCKS5_PROXY}"
else
    echo "==> [WARP] MicroWARP 未启用 (设置 ENABLE_WARP=1 以启用)"
fi

# ==========================================
# GitHub CLI 配置
# ==========================================
if [ -n "$GITHUB_TOKEN" ]; then
    echo "Configuring GitHub CLI with provided token..."
    mkdir -p /home/app/.config/gh
    echo "$GITHUB_TOKEN" | gh auth login --with-token 2>/dev/null \
        && gh auth setup-git 2>/dev/null \
        && echo "GitHub login success." \
        || echo "GitHub login failed."
fi

if [ -n "$GITHUB_SSH_KEY" ]; then
    echo "Configuring GitHub SSH key..."
    mkdir -p /home/app/.ssh
    echo "$GITHUB_SSH_KEY" | base64 -d > /home/app/.ssh/id_rsa
    chmod 600 /home/app/.ssh/id_rsa
    ssh-keyscan github.com >> /home/app/.ssh/known_hosts 2>/dev/null
    chown -R app:app /home/app/.ssh
    echo "GitHub SSH key configured."
fi

# ==========================================
# UID/GID 映射并启动多服务
# ==========================================
if [ "$(id -u)" = '0' ]; then
    LOCAL_UID=${LOCAL_UID:-10001}
    LOCAL_GID=${LOCAL_GID:-$LOCAL_UID}

    if [ "$(id -u app)" != "$LOCAL_UID" ] || [ "$(id -g app)" != "$LOCAL_GID" ]; then
        echo "Adjusting app user to uid=$LOCAL_UID, gid=$LOCAL_GID"
        groupmod -o -g "$LOCAL_GID" app
        usermod -o -u "$LOCAL_UID" -g "$LOCAL_GID" app
    fi

    # 提前创建并修正 code-server 的配置/数据目录，避免首次启动时权限错乱。
    mkdir -p /home/app/.config/code-server /home/app/.local/share/code-server /home/app/.paseo
    chown -R app:app /home/app /workspace 2>/dev/null || true

    exec gosu app /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
fi

exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
