#!/bin/bash
set -e

# ==========================================
# OpenChamber 服务配置
# ==========================================
# 监听地址：容器场景必须 0.0.0.0 才能被端口映射访问到，默认即 0.0.0.0。
export OPENCHAMBER_HOST="${OPENCHAMBER_HOST:-0.0.0.0}"
# UI 登录密码：未设置时 OpenChamber 无密码保护浏览器访问，
# 服务绑定 0.0.0.0 对外暴露前应务必设置该变量。
if [ -n "${OPENCHAMBER_UI_PASSWORD:-}" ]; then
    echo "==> [OpenChamber] UI password protection enabled (host=${OPENCHAMBER_HOST})"
else
    echo "==> [OpenChamber] WARNING: OPENCHAMBER_UI_PASSWORD is not set, browser UI has no authentication" >&2
fi

# ==========================================
# code-server 认证：优先使用哈希密码，其次明文密码。
# ==========================================
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
    if /usr/local/bin/init-warp.sh; then
        # microsocks 启用认证时（SOCKS_USER/SOCKS_PASS 非空），SOCKS5_PROXY 必须同步拼上账号密码，
        # 否则容器内依赖该变量的进程（opencode/codex 等）会因认证失败而无法走代理。
        if [ -n "${SOCKS_USER:-}" ] && [ -n "${SOCKS_PASS:-}" ]; then
            export SOCKS5_PROXY="socks5://${SOCKS_USER}:${SOCKS_PASS}@127.0.0.1:${WARP_SOCKS_PORT}"
            echo "==> [WARP] 环境变量已注入: SOCKS5_PROXY=socks5://***:***@127.0.0.1:${WARP_SOCKS_PORT}"
        else
            export SOCKS5_PROXY="socks5://127.0.0.1:${WARP_SOCKS_PORT}"
            echo "==> [WARP] 环境变量已注入: SOCKS5_PROXY=${SOCKS5_PROXY}"
        fi
    else
        echo "==> [WARP] WARNING: MicroWARP 初始化失败，跳过代理注入并继续启动主服务" >&2
    fi
else
    echo "==> [WARP] MicroWARP 未启用 (设置 ENABLE_WARP=1 以启用)"
fi

# ==========================================
# GitHub CLI 配置
# ==========================================
# gh 已不再通过 GITHUB_TOKEN 环境变量自动登录（历史方案已移除：
# 环境变量登录在实际使用中不稳定）。认证改走持久化配置卷：
# 首次使用时手动执行 `gh auth login`，凭据落在 ~/.config/gh
# （compose 已挂载 ./.config/gh 卷），容器重建后依然保持登录态。
# gh CLI 本体仍预装在 base 层，可正常使用。

if [ -n "$GITHUB_SSH_KEY" ]; then
    echo "Configuring GitHub SSH key..."
    mkdir -p /home/app/.ssh
    echo "$GITHUB_SSH_KEY" | base64 -d > /home/app/.ssh/id_rsa
    chmod 600 /home/app/.ssh/id_rsa
    GITHUB_SSH_KEYSCAN_TIMEOUT="${GITHUB_SSH_KEYSCAN_TIMEOUT:-10s}"
    if ! timeout "$GITHUB_SSH_KEYSCAN_TIMEOUT" ssh-keyscan github.com >> /home/app/.ssh/known_hosts 2>/dev/null; then
        echo "GitHub SSH known_hosts scan failed or timed out after ${GITHUB_SSH_KEYSCAN_TIMEOUT}; continuing startup." >&2
    fi
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
export PLAYWRIGHT_MCP_BROWSER=chrome
export PLAYWRIGHT_MCP_SANDBOX=0
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

    # 当 LOCAL_UID=0 时，app 用户将以 root 权限运行（UID=0），
    # 挂载目录的属主也是 root，无需递归 chown。
    # 注意：不能用 usermod -o -u 0 -g 0 app —— usermod -u 会递归遍历 /home/app
    # 逐个 chown 旧属主文件（/home/app 下挂载了 .cursor-server/.local/.cache 等
    # 数 G 数据），首次启动耗时可达数分钟，导致 healthcheck 在 supervisord 启动前
    # 就判容器 unhealthy。这里直接改 /etc/passwd、/etc/group 的账户元数据即可，
    # supervisord 的 user=app 只读 passwd 的 UID 字段决定降权目标，等价但不触发文件遍历。
    if [ "$LOCAL_UID" = "0" ]; then
        echo "Running as root (LOCAL_UID=0), patching /etc/passwd and /etc/group (no file scan)"
        if [ "$(id -u app)" != "0" ] || [ "$(id -g app)" != "0" ]; then
            sed -i 's/^\(app:[^:]*:\)[0-9]*:[0-9]*:/\10:0:/' /etc/passwd
            sed -i 's/^\(app:[^:]*:\)[0-9]*:/\10:/' /etc/group
            # 校验：失败必须立即暴露，否则 supervisord 的 user=app 会以错误身份运行。
            if [ "$(id -u app)" != "0" ] || [ "$(id -g app)" != "0" ]; then
                echo "FATAL: failed to set app uid/gid to 0 (passwd=$(getent passwd app))" >&2
                exit 1
            fi
        fi
    elif [ "$(id -u app)" != "$LOCAL_UID" ] || [ "$(id -g app)" != "$LOCAL_GID" ]; then
        echo "Adjusting app user to uid=$LOCAL_UID, gid=$LOCAL_GID"
        groupmod -o -g "$LOCAL_GID" app
        usermod -o -u "$LOCAL_UID" -g "$LOCAL_GID" app
    fi

    # 提前创建并修正 code-server 的配置/数据目录，避免首次启动时权限错乱。
    mkdir -p /home/app/.config/code-server /home/app/.local/share/code-server

    # supervisord 配置路径，供下方各段落的 sed 改写使用。
    SUPERVISOR_CONF="/etc/supervisor/supervisord.conf"

    # 当 LOCAL_UID=0 时，文件属主本身就是 root，无需递归 chown。
    if [ "$LOCAL_UID" != "0" ]; then
        chown -R app:app /home/app /workspace 2>/dev/null || true
    fi

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

        # 强制修正 host key 权限：容器重启或某些挂载场景会导致权限变宽（如 0777），
        # sshd 会拒绝使用过宽权限的私钥，导致公钥认证失效。
        # 覆盖全部可能的 host key 类型，避免 sshd 因 ecdsa/dsa key 权限过宽告警。
        chmod 600 /etc/ssh/ssh_host_ed25519_key /etc/ssh/ssh_host_rsa_key /etc/ssh/ssh_host_ecdsa_key /etc/ssh/ssh_host_dsa_key 2>/dev/null || true
        chmod 644 /etc/ssh/ssh_host_ed25519_key.pub /etc/ssh/ssh_host_rsa_key.pub /etc/ssh/ssh_host_ecdsa_key.pub /etc/ssh/ssh_host_dsa_key.pub 2>/dev/null || true

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

        # 多用户场景：同一份 authorized_keys 分发给 root/app/desktop 三个用户。
        # authorized_keys 本身支持每行一把公钥，多把公钥在宿主机文件里分行存放即可，
        # 不需要为每个用户单独挂载文件。这里不能用 >>（追加）：容器重启会重复叠加，
        # 必须用 cp（覆盖）保证幂等，来源是宿主机 :ro 挂载的唯一真相源文件。
        mkdir -p /root/.ssh
        cp /home/app/.ssh/authorized_keys /root/.ssh/authorized_keys
        chmod 700 /root/.ssh
        chmod 600 /root/.ssh/authorized_keys

        chmod 700 /home/app/.ssh
        chmod 600 /home/app/.ssh/authorized_keys
        chown -R app:app /home/app/.ssh

        # desktop 用户（多用户引入后必须显式分发，否则该账号无法 SSH 登录）
        mkdir -p /home/desktop/.ssh
        cp /home/app/.ssh/authorized_keys /home/desktop/.ssh/authorized_keys
        chmod 700 /home/desktop/.ssh
        chmod 600 /home/desktop/.ssh/authorized_keys
        chown -R desktop:desktop /home/desktop/.ssh

        /usr/sbin/sshd
        echo "==> [SSH] SSH Server 已启动，端口 2223，用户 root/app/desktop，公钥认证"
    else
        echo "==> [SSH] SSH Server 未启用 (挂载公钥到 /home/app/.ssh/authorized_keys 以启用)"
    fi

    # ==========================================
    # 远程桌面 (xrdp) 初始化（可选，通过 ENABLE_DESKTOP=1 开启）
    # xrdp 需要 root 权限（绑定端口 + PAM 认证），不能放进 supervisord。
    # 容器内无 systemd，必须手动启动 xrdp-sesman（会话管理器）和 xrdp（RDP 守护进程）
    # 同时手动拉起系统 D-Bus（xfce4-polkit / udisks2 / Thunar 挂载都依赖它）
    # 默认桌面：XFCE4（xfwm4 窗口管理器 + xfce4-panel 任务栏 + xfdesktop 桌面图标）
    # 中文输入法：fcitx5；端口：3390
    # 登录用户：
    #   - desktop（默认推荐）：独立普通权限账号，可 sudo。密码优先级：
    #       DESKTOP_USER_PASSWORD > DESKTOP_PASSWORD（复用）> 都空则无密码登录
    #   - app（可选，权限较高）：由 ALLOW_APP_DESKTOP 控制（1 允许 / 0 禁用），默认 1 保持向后兼容
    #     密码通过 DESKTOP_PASSWORD 设置（默认 "app"）
    # ==========================================
    if [ "${ENABLE_DESKTOP:-1}" = "1" ]; then
        /usr/local/bin/init-desktop.sh
    else
        echo "==> [Desktop] 远程桌面已禁用 (ENABLE_DESKTOP=${ENABLE_DESKTOP})"
    fi

    # ==========================================
    # DinD dockerd 开关（默认关闭以节省内存）
    # supervisord.conf 里 dockerd 默认 autostart=false，
    # 这里根据 ENABLE_DOCKERD 决定是否改为自启。
    # 运行中随时可手动拉起：supervisorctl start dockerd
    # ==========================================
    if [ "${ENABLE_DOCKERD:-0}" = "1" ]; then
        sed -i '/^\[program:dockerd\]/,/^\[/ s/^autostart=false/autostart=true/' "$SUPERVISOR_CONF"
        echo "==> [DockerD] 开机自启已启用 (ENABLE_DOCKERD=1)"
    else
        echo "==> [DockerD] 开机自启已关闭 (默认)。需要时运行: supervisorctl start dockerd"
    fi

    exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
fi

exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
