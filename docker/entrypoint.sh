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
# 持久化环境变量（供所有 shell 会话使用）
# ==========================================
cat > /etc/profile.d/opencode-env.sh <<'ENV_EOF'
export PNPM_HOME=/home/app/.local/share/pnpm
export PATH=/usr/local/go/bin:/home/app/go/bin:/opt/bun/bin:/opt/cargo/bin:/opt/flutter/bin:/opt/gradle-9.0.0/bin:/opt/gradle-7.5/bin:/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools:/opt/android-sdk/build-tools/35.0.1:/opt/apk-tools/bin:/opt/apk-tools/jadx/bin:/opt/apk-tools/dex2jar:/usr/lib/jvm/java-17-openjdk-current/bin:/home/app/.local/share/pnpm:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export GOPATH=/home/app/go
export BUN_INSTALL=/opt/bun
export RUSTUP_HOME=/opt/rustup
export CARGO_HOME=/opt/cargo
export ANDROID_SDK_ROOT=/opt/android-sdk
export ANDROID_HOME=/opt/android-sdk
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-current
export GRADLE_HOME=/opt/gradle-9.0.0
export PLAYWRIGHT_BROWSERS_PATH=/home/app/.cache/ms-playwright
export PLAYWRIGHT_MCP_HEADLESS=1
export PLAYWRIGHT_MCP_BROWSER=chromium
export PLAYWRIGHT_MCP_NO_SANDBOX=1
export ELECTRON_CACHE=/opt/electron-cache
export LANG=zh_CN.UTF-8
export LANGUAGE=zh_CN:zh
export LC_ALL=zh_CN.UTF-8
export EDITOR=vim
export PIP_BREAK_SYSTEM_PACKAGES=1
ENV_EOF
chmod +x /etc/profile.d/opencode-env.sh

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
    mkdir -p /home/app/.config/code-server /home/app/.local/share/code-server
    chown -R app:app /home/app /workspace 2>/dev/null || true

    # ==========================================
    # SSH Server 初始化（可选，通过挂载公钥文件启用）
    # 将宿主机公钥挂载到 /home/app/.ssh/authorized_keys 即可启用。
    # 必须在 gosu 降权之前（sshd 需要 root 权限）。
    # ==========================================
    if [ -f /home/app/.ssh/authorized_keys ] && [ -s /home/app/.ssh/authorized_keys ]; then
        echo "==> [SSH] 初始化 SSH Server..."

        mkdir -p /run/sshd /etc/ssh/sshd_config.d

        if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
            ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N '' -q
        fi
        if [ ! -f /etc/ssh/ssh_host_rsa_key ]; then
            ssh-keygen -t rsa -b 4096 -f /etc/ssh/ssh_host_rsa_key -N '' -q
        fi

        cat > /etc/ssh/sshd_config.d/opencode.conf <<EOF
Port 2223
PermitRootLogin yes
PubkeyAuthentication yes
PasswordAuthentication no
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding no
PrintMotd no
AcceptEnv LANG LC_*
EOF

        # root 的 authorized_keys 与 app 共用同一份公钥
        mkdir -p /root/.ssh
        cp /home/app/.ssh/authorized_keys /root/.ssh/authorized_keys
        chmod 700 /root/.ssh
        chmod 600 /root/.ssh/authorized_keys

        chmod 700 /home/app/.ssh
        chmod 600 /home/app/.ssh/authorized_keys
        chown -R app:app /home/app/.ssh
        /usr/sbin/sshd
        echo "==> [SSH] SSH Server 已启动，端口 2223，用户 root/app，公钥认证"
    else
        echo "==> [SSH] SSH Server 未启用 (挂载公钥到 /home/app/.ssh/authorized_keys 以启用)"
    fi

    # ==========================================
    # 远程桌面 (xrdp) 初始化（可选，通过 ENABLE_DESKTOP=1 开启）
    # xrdp 需要 root 权限（绑定端口 + PAM 认证），不能放进 supervisord（supervisord 以 app 用户运行）
    # 容器内无 systemd，必须手动启动 xrdp-sesman（会话管理器）和 xrdp（RDP 守护进程）
    # 默认桌面：LXQt；中文输入法：fcitx5；端口：3390
    # 登录凭据：与 SSH 共用 app 用户，密码通过 DESKTOP_PASSWORD 环境变量设置（默认 "app"）
    # ==========================================
    if [ "${ENABLE_DESKTOP:-1}" = "1" ]; then
        echo "==> [Desktop] 初始化 xrdp + LXQt 远程桌面..."

        # 设置 app 用户的 RDP 登录密码
        DESKTOP_PASSWORD="${DESKTOP_PASSWORD:-app}"
        echo "app:${DESKTOP_PASSWORD}" | chpasswd

        # 创建 app 用户的 .xsession 文件，xrdp 通过它判断启动哪个桌面
        cat > /home/app/.xsession <<'XSESSION_EOF'
exec startlxqt
XSESSION_EOF
        chown app:app /home/app/.xsession
        chmod 644 /home/app/.xsession

        # 修复 xrdp 运行时目录权限（ssl-cert 组成员由 Dockerfile.base 配置）
        mkdir -p /var/run/xrdp /tmp/.X11-unix
        touch /var/log/xrdp.log /var/log/xrdp-sesman.log
        chown xrdp:xrdp /var/run/xrdp /var/log/xrdp.log /var/log/xrdp-sesman.log
        chmod 2775 /var/run/xrdp
        chmod 1777 /tmp/.X11-unix

        # 先启动会话管理器，再启动 RDP 守护进程
        xrdp-sesman
        xrdp
        echo "==> [Desktop] xrdp 已启动，端口 3390，用户 app，登录密码由 DESKTOP_PASSWORD 提供"
        echo "==> [Desktop] RDP 客户端连接：localhost:3390（或宿主机映射端口）"
    else
        echo "==> [Desktop] 远程桌面已禁用 (ENABLE_DESKTOP=${ENABLE_DESKTOP})"
    fi

    exec gosu app /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
fi

exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
