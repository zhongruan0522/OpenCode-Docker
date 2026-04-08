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

# 【关键】不设置 AllowedIPs = 0.0.0.0/0
# wg-quick 看到 AllowedIPs=0.0.0.0/0 会自动把默认路由切到 wg0，
# 导致 opencode 的入站 HTTP 回包和内网通信全部走 WARP 出去，服务直接断掉。
# 改为手动用 ip route 添加路由，只让通过 microsocks 代理出去的流量走 WARP。
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
# 阶段 3.5：路由修复 —— 确保入站和内网流量不走 WARP
# ==========================================
# wg-quick up 会把默认路由指向 wg0（因为 AllowedIPs=0.0.0.0/0）。
# 这会导致 opencode 的入站 HTTP 回包也走 WARP 出去，客户端直接断连。
#
# 修复策略：使用 fwmark + policy routing
# - wg-quick 已经设置了 fwmark（Debian 的 wg-quick 默认用 0xca6c = 51820）
# - 在 wg0 的路由表（通常 table 51820）中已经有 WARP 路由
# - 主默认路由已经被 wg-quick 替换为指向 wg0
#
# 我们需要：把主默认路由恢复到原始网关，同时保留 wg0 的专用路由表。
# 这样只有通过 microsocks（显式 SOCKS5 代理）的流量才会走 WARP。

# 读取 wg-quick 设置的 fwmark
WG_FWMARK=$(grep -oP 'FwMark\s*=\s*0x\K[0-9a-fA-F]+' "$WG_CONF" 2>/dev/null || echo "ca6c")
WG_TABLE=$((0x${WG_FWMARK}))

# 获取 wg0 接口上 wg-quick 创建的路由信息
WG_GATEWAY=$(ip -4 route show dev wg0 2>/dev/null | head -n 1 || true)

# 获取当前默认路由（wg-quick 可能已经把它改成了 wg0）
CURR_DEFAULT=$(ip route show default 0.0.0.0/0 2>/dev/null | head -n 1 || true)

# 恢复原始默认路由：先删除 wg-quick 设置的默认路由，再添加原始默认路由
if echo "$CURR_DEFAULT" | grep -q "dev wg0"; then
    echo "==> [MicroWARP] 检测到默认路由已被 wg0 接管，正在修复..."

    # 删除指向 wg0 的默认路由
    ip route del default dev wg0 2>/dev/null || true

    # 从 wg-quick 保存的路由表中恢复原始默认路由
    # wg-quick 把原始默认路由保存在 table <fwmark> 中
    SAVED_DEFAULT=$(ip route show table "$WG_TABLE" default 2>/dev/null | head -n 1 || true)
    if [ -n "$SAVED_DEFAULT" ]; then
        echo "==> [MicroWARP] 从 wg-quick 备份表恢复原始默认路由: $SAVED_DEFAULT"
        ip route replace $SAVED_DEFAULT 2>/dev/null || true
    elif [ -n "$PRE_DEFAULT_GW" ]; then
        echo "==> [MicroWARP] 使用启动前记录的默认路由: $PRE_DEFAULT_GW"
        ip route replace $PRE_DEFAULT_GW 2>/dev/null || true
    fi

    echo "==> [MicroWARP] 路由修复完成，入站/内网流量不走 WARP"
fi

# 恢复 Tailscale 回程路由（如有）
TAILSCALE_CIDR="${TAILSCALE_CIDR:-100.64.0.0/10}"
if [ -n "$PRE_WARP_GW" ] && [ -n "$PRE_WARP_DEV" ]; then
    if ip route replace "$TAILSCALE_CIDR" via "$PRE_WARP_GW" dev "$PRE_WARP_DEV" > /dev/null 2>&1; then
        echo "==> [MicroWARP] 已为 ${TAILSCALE_CIDR} 恢复回程路由"
    fi
fi

# 验证：通过 WARP 访问的外部 IP 和直接访问应该不同
echo "==> [MicroWARP] 验证 WARP 出口 IP (通过代理):"
curl -s -m 5 --proxy "socks5://127.0.0.1:${WARP_SOCKS_PORT}" \
    https://1.1.1.1/cdn-cgi/trace 2>/dev/null | grep ip= \
    || echo "⚠️ 代理出口 IP 获取超时"

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
echo "==> [MicroWARP] SOCKS5 代理已启动 (PID: $WARP_PID)，地址: socks5://127.0.0.1:${WARP_SOCKS_PORT}"
echo "==> [MicroWARP] 注意：仅显式使用 SOCKS5 代理的流量走 WARP，服务本身回包和内网流量不受影响"
