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
    if /usr/local/bin/init-warp.sh; then
        export SOCKS5_PROXY="socks5://127.0.0.1:${WARP_SOCKS_PORT}"
        echo "==> [WARP] 环境变量已注入: SOCKS5_PROXY=${SOCKS5_PROXY}"
    else
        echo "==> [WARP] WARNING: MicroWARP 初始化失败，跳过代理注入并继续启动主服务" >&2
    fi
else
    echo "==> [WARP] MicroWARP 未启用 (设置 ENABLE_WARP=1 以启用)"
fi

# ==========================================
# GitHub CLI 配置
# ==========================================
if [ -n "$GITHUB_TOKEN" ]; then
    echo "Configuring GitHub CLI with provided token..."
    GITHUB_AUTH_TIMEOUT="${GITHUB_AUTH_TIMEOUT:-20s}"
    mkdir -p /home/app/.config/gh
    if echo "$GITHUB_TOKEN" | timeout "$GITHUB_AUTH_TIMEOUT" gh auth login --with-token >/dev/null 2>&1; then
        if timeout "$GITHUB_AUTH_TIMEOUT" gh auth setup-git >/dev/null 2>&1; then
            echo "GitHub login success."
        else
            echo "GitHub login success, but gh auth setup-git failed or timed out after ${GITHUB_AUTH_TIMEOUT}."
        fi
    else
        echo "GitHub login failed or timed out after ${GITHUB_AUTH_TIMEOUT}."
    fi
fi

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

    # 当 LOCAL_UID=0 时，app 用户将以 root 权限运行（UID=0），
    # 挂载目录的属主也是 root，无需递归 chown。
    # 注意：不能用 usermod -o -u 0 -g 0 app —— usermod -u 会递归遍历 /home/app
    # 逐个 chown 旧属主文件（/home/app 下挂载了 .cursor-server/.local/.cache 等
    # 数 G 数据），首次启动耗时可达数分钟，导致 healthcheck 在 supervisord 启动前
    # 就判容器 unhealthy。这里直接改 /etc/passwd、/etc/group 的账户元数据即可，
    # gosu app 只读 passwd 的 UID 字段决定降权目标，等价但不触发文件遍历。
    if [ "$LOCAL_UID" = "0" ]; then
        echo "Running as root (LOCAL_UID=0), patching /etc/passwd and /etc/group (no file scan)"
        if [ "$(id -u app)" != "0" ] || [ "$(id -g app)" != "0" ]; then
            sed -i 's/^\(app:[^:]*:\)[0-9]*:[0-9]*:/\10:0:/' /etc/passwd
            sed -i 's/^\(app:[^:]*:\)[0-9]*:/\10:/' /etc/group
            # 校验：失败必须立即暴露，否则 gosu app 会以错误身份运行
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

    # ==========================================
    # Open Design 初始化（自动启用）
    # supervisord 的 environment= 不会继承容器环境变量，必须在这里把
    # OD_API_TOKEN 写进 supervisord.conf，否则 daemon 检测到绑定了
    # 0.0.0.0 却没有 token 会拒绝启动，autorestart 陷入循环。
    # 未设置 OD_API_TOKEN 时自动生成随机 token 并打印到日志。
    # ==========================================
    mkdir -p /opt/open-design/.od
    if [ -z "${OD_API_TOKEN:-}" ]; then
        OD_API_TOKEN=$(openssl rand -hex 32)
        export OD_API_TOKEN
        echo "==> [Open Design] 自动生成 API Token: ${OD_API_TOKEN}"
    else
        echo "==> [Open Design] 使用用户提供的 API Token"
    fi
    chown -R app:app /opt/open-design/.od

    configure_open_design_supervisor() {
        local supervisor_config_path="$1"
        local open_design_api_token="$2"
        local escaped_open_design_api_token
        local open_design_environment_line
        local temporary_supervisor_config_path

        escaped_open_design_api_token="$(printf '%s' "$open_design_api_token" | sed 's/\\/\\\\/g; s/"/\\"/g')"
        open_design_environment_line="environment=HOME=\"/home/app\",USER=\"app\",SHELL=\"/bin/bash\",NODE_ENV=\"production\",NODE_OPTIONS=\"--max-old-space-size=384\",OD_BIND_HOST=\"0.0.0.0\",OD_PORT=\"4098\",OD_DATA_DIR=\"/opt/open-design/.od\",OD_API_TOKEN=\"${escaped_open_design_api_token}\""
        temporary_supervisor_config_path="${supervisor_config_path}.tmp"

        if awk -v environment_line="$open_design_environment_line" '
            /^\[program:open-design\]$/ {
                inside_open_design_program = 1
                print
                next
            }
            inside_open_design_program && /^\[/ {
                inside_open_design_program = 0
            }
            inside_open_design_program && /^environment=/ {
                print environment_line
                replaced_environment = 1
                next
            }
            inside_open_design_program && /^autostart=/ {
                print "autostart=true"
                replaced_autostart = 1
                next
            }
            { print }
            END {
                if (!replaced_environment || !replaced_autostart) {
                    exit 42
                }
            }
        ' "$supervisor_config_path" > "$temporary_supervisor_config_path"; then
            mv "$temporary_supervisor_config_path" "$supervisor_config_path"
        else
            rm -f "$temporary_supervisor_config_path"
            echo "FATAL: failed to configure [program:open-design] in ${supervisor_config_path}" >&2
            exit 1
        fi
    }

    configure_open_design_supervisor "$SUPERVISOR_CONF" "$OD_API_TOKEN"
    echo "==> [Open Design] 已启用，端口 4098"

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
    # 同时手动拉起系统 D-Bus（xfce4-polkit / udisks2 / Thunar 挂载都依赖它）
    # 默认桌面：XFCE4（xfwm4 窗口管理器 + xfce4-panel 任务栏 + xfdesktop 桌面图标）
    # 中文输入法：fcitx5；端口：3390
    # 登录凭据：与 SSH 共用 app 用户，密码通过 DESKTOP_PASSWORD 环境变量设置（默认 "app"）
    # ==========================================
    if [ "${ENABLE_DESKTOP:-1}" = "1" ]; then
        echo "==> [Desktop] 初始化 xrdp + XFCE4 远程桌面..."

        # 设置 app 用户的 RDP 登录密码
        DESKTOP_PASSWORD="${DESKTOP_PASSWORD:-app}"
        echo "app:${DESKTOP_PASSWORD}" | chpasswd

        # 创建 app 用户的 .xsession 文件，xrdp 通过它判断启动哪个桌面
        cat > /home/app/.xsession <<'XSESSION_EOF'
exec startxfce4
XSESSION_EOF
        chown app:app /home/app/.xsession
        chmod 644 /home/app/.xsession

        # 启动系统 D-Bus（容器内无 systemd 不会自动起）
        # 解决 XFCE 下 polkit / udisks2 / Thunar 挂载 / 网络管理器等组件的 "Not connected to D-Bus server"
        if command -v dbus-daemon >/dev/null 2>&1; then
            mkdir -p /run/dbus
            # 若已有 dbus-daemon 在跑（容器热重启场景），先静默干掉再重启
            if [ -f /run/dbus/pid ]; then
                kill "$(cat /run/dbus/pid 2>/dev/null)" 2>/dev/null || true
                rm -f /run/dbus/pid
            fi
            dbus-daemon --system --fork
            echo "==> [Desktop] 系统 D-Bus 已启动"
        fi

        # 修复 xrdp 运行时目录权限（ssl-cert 组成员由 Dockerfile.base 配置）
        mkdir -p /var/run/xrdp /tmp/.X11-unix
        touch /var/log/xrdp.log /var/log/xrdp-sesman.log
        chown xrdp:xrdp /var/run/xrdp /var/log/xrdp.log /var/log/xrdp-sesman.log
        chmod 2775 /var/run/xrdp
        chmod 1777 /tmp/.X11-unix

        # 清理上次运行残留的 pid 文件：
        # 容器重启时进程已死，但 /var/run/xrdp/xrdp-sesman.pid 可能残留，
        # 导致 xrdp-sesman 误判为 "is already running" 并以非零退出，
        # 在 set -e 作用下会让整个 entrypoint 退出、容器陷入重启循环。
        rm -f /var/run/xrdp/xrdp-sesman.pid /var/run/xrdp/xrdp.pid

        # 先启动会话管理器，再启动 RDP 守护进程
        # xrdp-sesman/xrdp 以 daemon 模式运行（默认行为），立即返回 0
        xrdp-sesman
        xrdp
        echo "==> [Desktop] xrdp 已启动，端口 3390，用户 app，登录密码由 DESKTOP_PASSWORD 提供"
        echo "==> [Desktop] RDP 客户端连接：localhost:3390（或宿主机映射端口）"
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

    exec gosu app /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
fi

exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
