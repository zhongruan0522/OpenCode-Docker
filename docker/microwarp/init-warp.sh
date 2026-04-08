#!/bin/sh
# MicroWARP 初始化脚本
# 基于 https://github.com/ccbkkb/MicroWARP，缝合进 OpenCode-Docker
# 仅提供内部 SOCKS5 代理，不对外暴露端口
#
# 路由策略：WARP 仅作为出口代理，opencode 的入站 HTTP 服务回包
# 和内网通信走原始默认路由，不经过 WARP

set -e

WG_CONF="/etc/wireguard/wg0.conf"
WARP_SOCKS_PORT="${WARP_SOCKS_PORT:-1080}"
mkdir -p /etc/wireguard

# wgcf 下载辅助函数，支持 GH_PROXY 代理前缀
build_wgcf_download_url() {
    WGCF_VER=$1
    WGCF_ARCH=$2
    RAW_URL="https://github.com/ViRb3/wgcf/releases/download/v${WGCF_VER}/wgcf_${WGCF_VER}_linux_${WGCF_ARCH}"
    if [ -n "${GH_PROXY:-}" ]; then
        echo "${GH_PROXY%/}/${RAW_URL}"
        return 0
    fi
    echo "$RAW_URL"
}

# ==========================================
# 阶段 1：自动注册 Cloudflare WARP 设备
# ==========================================
if [ ! -f "$WG_CONF" ]; then
    echo "==> [MicroWARP] 未检测到配置，正在全自动初始化 Cloudflare WARP..."

    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  WGCF_ARCH="amd64" ;;
        aarch64) WGCF_ARCH="arm64" ;;
        *) echo "==> [MicroWARP ERROR] 不支持的架构: $ARCH"; exit 1 ;;
    esac

    WGCF_VER=$(curl -sL https://api.github.com/repos/ViRb3/wgcf/releases/latest \
        | grep '"tag_name"' | sed 's/.*"v\(.*\)".*/\1/')
    echo "==> [MicroWARP] wgcf 最新版本: v${WGCF_VER}"

    wget --timeout=15 -qO /tmp/wgcf \
        "$(build_wgcf_download_url "$WGCF_VER" "$WGCF_ARCH")"
    chmod +x /tmp/wgcf

    echo "==> [MicroWARP] 正在向 Cloudflare 注册设备..."
    cd /tmp && ./wgcf register --accept-tos > /dev/null

    echo "==> [MicroWARP] 正在生成 WireGuard 配置文件..."
    ./wgcf generate > /dev/null
    mv /tmp/wgcf-profile.conf "$WG_CONF"

    # 阅后即焚：删除注册工具和账号明文
    rm -f /tmp/wgcf /tmp/wgcf-account.toml
    echo "==> [MicroWARP] 节点配置生成成功！"
else
    echo "==> [MicroWARP] 检测到已有持久化配置，跳过注册。"
fi

# ==========================================
# 阶段 2：配置清洗与内核兼容性处理
# ==========================================
# 智能提取纯 IPv4 地址，防止双栈 IP 写在同一行导致误杀
IPV4_ADDR=$(grep '^Address' "$WG_CONF" \
    | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}' | head -n 1)

# 物理删除原始 Address/AllowedIPs/DNS
sed -i '/^Address/d'       "$WG_CONF"
sed -i '/^AllowedIPs/d'    "$WG_CONF"
sed -i '/^DNS.*/d'         "$WG_CONF"

# 重建 IPv4 地址
if [ -n "$IPV4_ADDR" ]; then
    sed -i "/\[Interface\]/a Address = $IPV4_ADDR" "$WG_CONF"
fi

# 保留 AllowedIPs = 0.0.0.0/0，让 wg-quick 接管默认公网出站到 WARP。
# 后面仅为私网/本地回程补更具体的绕过路由，满足“公网全走 WARP，本地地址不走”。
sed -i "/\[Peer\]/a AllowedIPs = 0.0.0.0\/0" "$WG_CONF"

# wg-quick 在 Debian 上不会出现 src_valid_mark 问题，但保险起见做检查
if command -v wg-quick >/dev/null 2>&1; then
    WG_QUICK_BIN=$(command -v wg-quick)
    if grep -q 'src_valid_mark' "$WG_QUICK_BIN" 2>/dev/null; then
        sed -i '/src_valid_mark/d' "$WG_QUICK_BIN"
    fi
fi

# 注入 15 秒 UDP 心跳保活，对抗运营商 QoS 丢包
if ! grep -q "PersistentKeepalive" "$WG_CONF"; then
    sed -i '/\[Peer\]/a PersistentKeepalive = 15' "$WG_CONF"
else
    sed -i 's/PersistentKeepalive.*/PersistentKeepalive = 15/g' "$WG_CONF"
fi

# 自定义 Endpoint IP，用于绕过某些机房的 QoS 限制
if [ -n "${ENDPOINT_IP:-}" ]; then
    echo "==> [MicroWARP] 检测到自定义 Endpoint: $ENDPOINT_IP"
    sed -i "s/^Endpoint.*/Endpoint = $ENDPOINT_IP/g" "$WG_CONF"
fi

# ==========================================
# 阶段 3：启动 WireGuard 并修复路由
# ==========================================
# 记录 WARP 启动前的默认路由和网关信息，用于后续恢复
PRE_DEFAULT_GW=$(ip route show default 0.0.0.0/0 2>/dev/null | head -n 1 || true)
PRE_WARP_ROUTE=$(ip route get 100.64.0.1 2>/dev/null | head -n 1 || true)
PRE_WARP_GW=$(printf '%s\n' "$PRE_WARP_ROUTE" \
    | awk '{for (i = 1; i <= NF; i++) if ($i == "via") print $(i + 1)}')
PRE_WARP_DEV=$(printf '%s\n' "$PRE_WARP_ROUTE" \
    | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") print $(i + 1)}')

echo "==> [MicroWARP] 正在启动内核级 wg0 网卡..."
wg-quick up wg0 > /dev/null 2>&1

# ==========================================
# 阶段 3.5：补私网绕过路由
# ==========================================
# wg-quick 会把默认公网流量切到 wg0，但 main 表里的更具体路由仍然优先生效。
# 这里为 RFC1918、链路本地和 Tailscale CGNAT 地址补回原网关路由，
# 让 10/172/192/100.64 等本地地址不走 WARP。

PRE_DEFAULT_GW_IP=$(printf '%s\n' "$PRE_DEFAULT_GW" | awk '{for (i = 1; i <= NF; i++) if ($i == "via") print $(i + 1)}')
PRE_DEFAULT_DEV=$(printf '%s\n' "$PRE_DEFAULT_GW" | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") print $(i + 1)}')
WARP_BYPASS_CIDRS=${WARP_BYPASS_CIDRS:-"10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 100.64.0.0/10"}

if [ -n "$PRE_DEFAULT_GW_IP" ] && [ -n "$PRE_DEFAULT_DEV" ]; then
    echo "==> [MicroWARP] 正在恢复私网绕过路由..."
    for cidr in $WARP_BYPASS_CIDRS; do
        if ip route replace "$cidr" via "$PRE_DEFAULT_GW_IP" dev "$PRE_DEFAULT_DEV" > /dev/null 2>&1; then
            echo "==> [MicroWARP] 已添加绕过路由: $cidr via $PRE_DEFAULT_GW_IP dev $PRE_DEFAULT_DEV"
        fi
    done
else
    echo "==> [MicroWARP] 未检测到启动前默认网关，跳过私网绕过路由恢复"
fi

# 恢复 Tailscale 回程路由（如有）
TAILSCALE_CIDR="${TAILSCALE_CIDR:-100.64.0.0/10}"
if [ -n "$PRE_WARP_GW" ] && [ -n "$PRE_WARP_DEV" ]; then
    if ip route replace "$TAILSCALE_CIDR" via "$PRE_WARP_GW" dev "$PRE_WARP_DEV" > /dev/null 2>&1; then
        echo "==> [MicroWARP] 已为 ${TAILSCALE_CIDR} 恢复回程路由"
    fi
fi

# ==========================================
# 阶段 4：启动 SOCKS5 代理（仅监听 localhost）
# ==========================================
echo "==> [MicroWARP] 启动 MicroSOCKS 引擎，监听 127.0.0.1:${WARP_SOCKS_PORT}"

if [ -n "${SOCKS_USER:-}" ] && [ -n "${SOCKS_PASS:-}" ]; then
    echo "==> [MicroWARP] SOCKS5 认证已开启 (User: $SOCKS_USER)"
    microsocks -i 127.0.0.1 -p "$WARP_SOCKS_PORT" \
        -u "$SOCKS_USER" -P "$SOCKS_PASS" &
else
    microsocks -i 127.0.0.1 -p "$WARP_SOCKS_PORT" &
fi

WARP_PID=$!
# 等待 microsocks 就绪
sleep 1

# 验证 microsocks 是否成功启动，避免后续误以为 WARP 已可用
if ! kill -0 "$WARP_PID" 2>/dev/null; then
    echo "==> [MicroWARP ERROR] microsocks failed to stay alive after startup"
    exit 1
fi

# 验证路由：公网默认应走 WARP，私网地址应命中原网关的更具体路由。
echo "==> [MicroWARP] 验证路由 (公网出口，应为 WARP):"
curl -s -m 5 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | grep -E 'ip=' | head -1 \
    || echo "⚠️ 公网出口 IP 获取超时"
echo "==> [MicroWARP] 验证路由 (本地 SOCKS5 代理出口，应同样为 WARP):"
curl -s -m 5 --proxy "socks5://127.0.0.1:${WARP_SOCKS_PORT}" \
    https://1.1.1.1/cdn-cgi/trace 2>/dev/null | grep -E 'ip=' | head -1 \
    || echo "⚠️ 代理出口 IP 获取超时"
echo "==> [MicroWARP] 验证私网绕过路由 (192.168.1.1):"
ip route get 192.168.1.1 2>/dev/null | head -n 1 || echo "⚠️ 私网路由查询失败"

echo "==> [MicroWARP] SOCKS5 代理已启动 (PID: $WARP_PID)，地址: socks5://127.0.0.1:${WARP_SOCKS_PORT}"
echo "==> [MicroWARP] 当前模式：公网默认走 WARP，私网/本地地址按更具体路由直连绕过"
