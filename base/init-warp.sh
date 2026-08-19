#!/bin/sh
# MicroWARP 初始化脚本
# 基于 https://github.com/ccbkkb/MicroWARP，缝合进 OpenCode-Docker
# 提供 SOCKS5 代理（默认监听 0.0.0.0，容器内/内层 Docker 均可使用）
# 可通过 WARP_SOCKS_BIND 环境变量控制监听地址
#
# 路由策略：WARP 仅作为出口代理，opencode 的入站 HTTP 服务回包
# 和内网通信走原始默认路由，不经过 WARP
#
# 协议：WireGuard（内核，默认） | MASQUE（usque 用户态，TUNNEL_PROTOCOL=masque）

set -e

# 静默模式：所有中间日志重定向，仅通过 warp_log / warp_ok / warp_fail 输出
_EXEC_LOG="/tmp/microwarp-init.log"
_WARP_EXIT_IP=""

warp_log() { :; }
warp_ok()   { echo "==> [WARP] ✅ WARP 代理启动成功"; }
warp_fail() { echo "==> [WARP] ❌ WARP 代理启动失败 (日志: $_EXEC_LOG)"; exit 1; }

WG_CONF="/etc/wireguard/wg0.conf"
# wgcf 注册得到的 IPv6 地址镜像缓存：sanitize 每次都会原地重写 wg0.conf，
# 纯 IPv4 模式跑一次后 Address 行的 v6 地址即被删除；镜像到本文件（同卷持久化）
# 后，后续开启 ENABLE_WARP_IPV6=1 可直接恢复双栈，无需删卷重新注册。
WG_V6_CACHE="/etc/wireguard/wg0.v6addr"
WARP_SOCKS_PORT="${WARP_SOCKS_PORT:-1080}"
WARP_SOCKS_BIND="${WARP_SOCKS_BIND:-0.0.0.0}"

# wgcf 下载可靠性参数（吸收自上游 81248d6 / 5655bd6）
WGCF_FALLBACK_VER="${WGCF_FALLBACK_VER:-2.2.29}"
CURL_TIMEOUT="${CURL_TIMEOUT:-15}"

# WireGuard 调优参数（吸收自上游 904e9c1）
WG_MTU="${MTU:-1280}"
KEEPALIVE="${KEEPALIVE:-15}"

# 双栈 WARP（IPv4+IPv6 出口），默认 0 保持纯 IPv4；
# 运行时用 is_truthy "${ENABLE_WARP_IPV6:-0}" 判定，避免在 is_truthy 定义前求值

# MASQUE / usque（吸收自上游 8045ba9 / d71f750）
# 配置与 WireGuard 同置于 /etc/wireguard，warp-data 卷可同时持久化两种协议身份
TUNNEL_PROTOCOL="${TUNNEL_PROTOCOL:-wireguard}"
USQUE_CONFIG="${USQUE_CONFIG:-/etc/wireguard/masque-config.json}"
# l4-socks = 轻量 TCP-only（推荐）；socks = 完整 gVisor L3（TCP+UDP，更重）
MASQUE_PROXY_MODE="${MASQUE_PROXY_MODE:-l4-socks}"
MASQUE_HTTP2="${MASQUE_HTTP2:-0}"
WARP_JWT="${WARP_JWT:-}"
WARP_LICENSE="${WARP_LICENSE:-}"
USQUE_DEVICE_NAME="${USQUE_DEVICE_NAME:-MicroWARP}"
# 小内存宿主机上约束 Go 运行时 RSS（仅 MASQUE 路径生效）
GOMEMLIMIT="${GOMEMLIMIT:-512MiB}"

# 注意：所有立即执行语句统一收口到 main()，函数定义区不放裸命令。
# 原因：set -e 下 dash/bash 分块读取脚本时，定义区中间的外部命令（如 mkdir）
# 会改变脚本文件读偏移，导致其后定义的函数在 $( ) 子 shell 中查不到（127）。

# ==========================================
# 工具函数
# ==========================================
github_auth_header() {
    token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
    if [ -n "$token" ]; then
        printf 'Authorization: Bearer %s' "$token"
    fi
}

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

# GitHub API 限流/不可达时回退到锁定版本，避免首启死锁（上游 5655bd6）
fetch_latest_wgcf_version() {
    api="https://api.github.com/repos/ViRb3/wgcf/releases/latest"
    auth="$(github_auth_header)"
    body=""
    if [ -n "$auth" ]; then
        body="$(curl -fsSL -m "$CURL_TIMEOUT" -H "$auth" "$api" 2>/dev/null || true)"
    else
        body="$(curl -fsSL -m "$CURL_TIMEOUT" "$api" 2>/dev/null || true)"
    fi
    ver="$(printf '%s' "$body" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\([^"]*\)".*/\1/p' | head -n 1)"
    if [ -z "$ver" ]; then
        echo "==> [WARP] WARNING: GitHub API 获取 wgcf 版本失败，回退到 v${WGCF_FALLBACK_VER}" >&2
        printf '%s' "$WGCF_FALLBACK_VER"
        return 0
    fi
    printf '%s' "$ver"
}

# wget/curl 双通道 + 3 次递增退避重试（上游 5655bd6）
download_file() {
    url=$1
    dest=$2
    tries=0
    max_tries=3
    while [ "$tries" -lt "$max_tries" ]; do
        tries=$((tries + 1))
        if command -v wget >/dev/null 2>&1; then
            if wget --timeout=30 -qO "$dest" "$url" 2>/dev/null; then
                [ -s "$dest" ] && return 0
            fi
        fi
        if command -v curl >/dev/null 2>&1; then
            if curl -fsSL -m 30 -o "$dest" "$url" 2>/dev/null; then
                [ -s "$dest" ] && return 0
            fi
        fi
        sleep $((tries * 2))
    done
    return 1
}

is_truthy() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

# 提取首个 IPv6 CIDR（逗号/空格分隔，含 ':' 的 token）
extract_ipv6_cidr() {
    printf '%s\n' "$1" \
        | tr ',' '\n' | tr ' ' '\n' \
        | grep -E '^[0-9a-fA-F:]+/[0-9]{1,3}$' \
        | grep ':' \
        | head -n 1
}

# wg0 是否已有全局 IPv6 地址（无则探测跳过，上游 857c7a3）
iface_has_global_ipv6() {
    ip -6 addr show dev "$1" scope global 2>/dev/null | grep -q 'inet6 '
}

normalize_tunnel_protocol() {
    raw="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    case "$raw" in
        wireguard|wg|wg0|kernel) printf 'wireguard' ;;
        masque|usque|h3|http3|quic) printf 'masque' ;;
        *) echo "==> [WARP] ❌ 未知 TUNNEL_PROTOCOL='$1'（支持: wireguard | masque）" >&2; exit 1 ;;
    esac
}

normalize_masque_proxy_mode() {
    raw="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    case "$raw" in
        l4|l4-socks|l4_socks|l4socks) printf 'l4-socks' ;;
        socks|full|gvisor|l3) printf 'socks' ;;
        *) echo "==> [WARP] ❌ 未知 MASQUE_PROXY_MODE='$1'（支持: l4-socks | socks）" >&2; exit 1 ;;
    esac
}

# ==========================================
# WireGuard 路径 - 阶段 1：自动注册 Cloudflare WARP 设备
# ==========================================
register_warp() {
    warp_log "未检测到配置，正在全自动初始化 Cloudflare WARP..."

    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  WGCF_ARCH="amd64" ;;
        aarch64) WGCF_ARCH="arm64" ;;
        *) echo "==> [WARP] ❌ 不支持的架构: $ARCH"; exit 1 ;;
    esac

    WGCF_VER="$(fetch_latest_wgcf_version)"
    warp_log "wgcf 版本: v${WGCF_VER} (${WGCF_ARCH})"

    # mktemp 隔离工作目录，注册材料阅后即焚（上游 5655bd6）
    workdir="$(mktemp -d /tmp/microwarp.XXXXXX)" || exit 1

    if ! download_file "$(build_wgcf_download_url "$WGCF_VER" "$WGCF_ARCH")" "$workdir/wgcf"; then
        rm -rf "$workdir"
        echo "==> [WARP] ❌ wgcf 二进制下载失败" >&2
        exit 1
    fi
    chmod +x "$workdir/wgcf"

    warp_log "正在向 Cloudflare 注册设备..."
    if ! (
        cd "$workdir"
        ./wgcf register --accept-tos > /dev/null 2>&1
        warp_log "正在生成 WireGuard 配置文件..."
        ./wgcf generate > /dev/null 2>&1
    ); then
        rm -rf "$workdir"
        echo "==> [WARP] ❌ wgcf 注册或配置生成失败" >&2
        exit 1
    fi

    if [ ! -f "$workdir/wgcf-profile.conf" ]; then
        rm -rf "$workdir"
        echo "==> [WARP] ❌ 未找到 wgcf-profile.conf，注册可能失败" >&2
        exit 1
    fi

    mv "$workdir/wgcf-profile.conf" "$WG_CONF"
    # 阅后即焚：删除注册工具和账号明文
    rm -rf "$workdir"
    warp_log "节点配置生成成功！"
}

# ==========================================
# WireGuard 路径 - 阶段 2：配置清洗与内核兼容性处理
# ==========================================
sanitize_wg_config() {
    # wgcf 写出的配置可能是零字节残留（注册中途被杀），必须重新注册（上游 d71f750 思路）
    if [ -f "$WG_CONF" ] && [ ! -s "$WG_CONF" ]; then
        warp_log "检测到零字节残留配置，删除后重新注册..."
        rm -f "$WG_CONF"
    fi

    if [ ! -f "$WG_CONF" ]; then
        register_warp
    else
        warp_log "检测到已有持久化配置，跳过注册。"
    fi

    # 智能提取纯 IPv4 地址，防止双栈 IP 写在同一行导致误杀
    IPV4_ADDR=$(grep '^Address' "$WG_CONF" \
        | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}' | head -n 1)
    if [ -z "$IPV4_ADDR" ]; then
        echo "==> [WARP] ❌ 无法从配置解析 IPv4 Address，配置可能已损坏" >&2
        exit 1
    fi

    # ENABLE_WARP_IPV6=1 时提取 IPv6 地址，构建双栈 Address。
    # 提取顺序：当前配置 → v6 缓存（历史注册时镜像保存），都无则告警降级纯 IPv4。
    ADDRESS_VALUE="$IPV4_ADDR"
    IPV6_ADDR=""
    if is_truthy "${ENABLE_WARP_IPV6:-0}"; then
        IPV6_ADDR=$(extract_ipv6_cidr "$(grep '^Address' "$WG_CONF")")
        if [ -z "$IPV6_ADDR" ] && [ -f "$WG_V6_CACHE" ]; then
            IPV6_ADDR=$(head -n 1 "$WG_V6_CACHE" 2>/dev/null || true)
            [ -n "$IPV6_ADDR" ] && warp_log "从缓存 ${WG_V6_CACHE} 恢复 IPv6 地址: $IPV6_ADDR"
        fi
        if [ -n "$IPV6_ADDR" ]; then
            ADDRESS_VALUE="${IPV4_ADDR},${IPV6_ADDR}"
            warp_log "双栈地址: IPv4=${IPV4_ADDR} IPv6=${IPV6_ADDR}"
        else
            echo "==> [WARP] ⚠️  ENABLE_WARP_IPV6=1 但配置与缓存均无 IPv6 地址，仅启用 IPv4" >&2
        fi
    fi

    # 注册得到的 v6 地址镜像到缓存（配置里有而缓存缺失/过期时刷新），
    # 确保纯 IPv4 模式的 sanitize 重写不会永久丢失 v6 身份。
    CONF_V6_ADDR=$(extract_ipv6_cidr "$(grep '^Address' "$WG_CONF")")
    if [ -n "$CONF_V6_ADDR" ] && [ "$CONF_V6_ADDR" != "$(cat "$WG_V6_CACHE" 2>/dev/null || true)" ]; then
        printf '%s\n' "$CONF_V6_ADDR" > "$WG_V6_CACHE" 2>/dev/null \
            || echo "==> [WARP] ⚠️  IPv6 地址缓存写入失败（${WG_V6_CACHE}），不影响当前启动" >&2
    fi

    # 物理删除原始 Address/AllowedIPs/DNS/MTU
    sed -i '/^Address/d'       "$WG_CONF"
    sed -i '/^AllowedIPs/d'    "$WG_CONF"
    sed -i '/^DNS.*/d'         "$WG_CONF"
    # 清除可能存在的旧 MTU（兼容 Busybox 正则）
    sed -i '/^[Mm][Tt][Uu].*/d' "$WG_CONF"

    # 重建地址（双栈或纯 IPv4）
    sed -i "/\[Interface\]/a Address = $ADDRESS_VALUE" "$WG_CONF"

    # 动态注入 MTU，默认 1280 避免 PPPoE/IPIP 等小 MTU 链路分片（上游 904e9c1）
    warp_log "MTU 值设置为: $WG_MTU"
    sed -i "/\[Interface\]/a MTU = $WG_MTU" "$WG_CONF"

    # 保留 AllowedIPs = 0.0.0.0/0，让 wg-quick 接管默认公网出站到 WARP。
    # 后面仅为私网/本地回程补更具体的绕过路由，满足"公网全走 WARP，本地地址不走"。
    # 双栈时追加 ::/0（由 $IPV6_ADDR 非空保证配置侧已有 v6 地址）。
    if is_truthy "${ENABLE_WARP_IPV6:-0}" && [ -n "${IPV6_ADDR:-}" ]; then
        sed -i "/\[Peer\]/a AllowedIPs = 0.0.0.0\/0,::\/0" "$WG_CONF"
    else
        sed -i "/\[Peer\]/a AllowedIPs = 0.0.0.0\/0" "$WG_CONF"
    fi

    # wg-quick 在 Debian 上不会出现 src_valid_mark 问题，但保险起见做检查
    if command -v wg-quick >/dev/null 2>&1; then
        WG_QUICK_BIN=$(command -v wg-quick)
        # 双栈时先确保内核允许 IPv6（部分基础镜像默认 disable_ipv6=1）
        if is_truthy "${ENABLE_WARP_IPV6:-0}" && [ -n "${IPV6_ADDR:-}" ]; then
            sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1 || true
            sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1 || true
        fi
        if grep -q 'src_valid_mark' "$WG_QUICK_BIN" 2>/dev/null; then
            sed -i '/src_valid_mark/d' "$WG_QUICK_BIN"
        fi
    fi

    # 注入 UDP 心跳保活（秒数可配，默认 15），对抗运营商 QoS 丢包（上游 904e9c1）
    if ! grep -q "PersistentKeepalive" "$WG_CONF"; then
        sed -i "/\[Peer\]/a PersistentKeepalive = $KEEPALIVE" "$WG_CONF"
    else
        sed -i "s/PersistentKeepalive.*/PersistentKeepalive = $KEEPALIVE/g" "$WG_CONF"
    fi

    # 自定义 Endpoint IP，用于绕过某些机房的 QoS 限制
    # 注意：set -e 下函数若以 [ -n ] 假分支结尾会返回非零、误杀整个脚本，显式 return 0
    if [ -n "${ENDPOINT_IP:-}" ]; then
        warp_log "检测到自定义 Endpoint: $ENDPOINT_IP"
        if grep -qi '^[[:space:]]*Endpoint[[:space:]]*=' "$WG_CONF"; then
            sed -i "s|^[[:space:]]*Endpoint[[:space:]]*=.*|Endpoint = ${ENDPOINT_IP}|g" "$WG_CONF"
        else
            sed -i "/\[Peer\]/a Endpoint = ${ENDPOINT_IP}" "$WG_CONF"
        fi
    fi
    return 0
}

# ==========================================
# WireGuard 路径 - 阶段 3：启动 WireGuard 并修复路由
# ==========================================
start_wireguard() {
    # 记录 WARP 启动前的默认路由和网关信息，用于后续恢复
    PRE_DEFAULT_GW=$(ip route show default 0.0.0.0/0 2>/dev/null | head -n 1 || true)
    PRE_WARP_ROUTE=$(ip route get 100.64.0.1 2>/dev/null | head -n 1 || true)
    PRE_WARP_GW=$(printf '%s\n' "$PRE_WARP_ROUTE" \
        | awk '{for (i = 1; i <= NF; i++) if ($i == "via") print $(i + 1)}')
    PRE_WARP_DEV=$(printf '%s\n' "$PRE_WARP_ROUTE" \
        | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") print $(i + 1)}')

    warp_log "正在启动内核级 wg0 网卡..."
    # wg-quick 失败时把输出落盘到 _EXEC_LOG 并打印关键行，错误必须暴露；
    # IPv6 场景失败常见于宿主无 v6 支持，提示可设 ENABLE_WARP_IPV6=0 回退。
    if ! wg-quick up wg0 > "$_EXEC_LOG" 2>&1; then
        echo "==> [WARP] ❌ wg-quick up wg0 失败（日志: $_EXEC_LOG）：" >&2
        tail -n 20 "$_EXEC_LOG" >&2
        echo "==> [WARP] ❌ 若为 IPv6 相关报错，可设 ENABLE_WARP_IPV6=0 回退纯 IPv4" >&2
        warp_fail
    fi

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
        warp_log "正在恢复私网绕过路由..."
        for cidr in $WARP_BYPASS_CIDRS; do
            if ip route replace "$cidr" via "$PRE_DEFAULT_GW_IP" dev "$PRE_DEFAULT_DEV" > /dev/null 2>&1; then
                warp_log "已添加绕过路由: $cidr via $PRE_DEFAULT_GW_IP dev $PRE_DEFAULT_DEV"
            fi
        done

        # 双栈时为 IPv6 ULA/链路本地补绕过路由（镜像无 v6 默认网关场景常见为空，容错跳过）
        if is_truthy "${ENABLE_WARP_IPV6:-0}"; then
            PRE_DEFAULT_GW_V6=$(ip -6 route show default 2>/dev/null | head -n 1 \
                | awk '{for (i = 1; i <= NF; i++) if ($i == "via") print $(i + 1)}')
            if [ -n "$PRE_DEFAULT_GW_V6" ]; then
                for cidr in fd00::/8 fe80::/10; do
                    if ip -6 route replace "$cidr" via "$PRE_DEFAULT_GW_V6" dev "$PRE_DEFAULT_DEV" > /dev/null 2>&1; then
                        warp_log "已添加 IPv6 绕过路由: $cidr via $PRE_DEFAULT_GW_V6"
                    fi
                done
            fi
        fi

        # Docker 发布端口的公网入站连接会 DNAT 到容器主网卡地址。
        # 响应包源地址固定为该主网卡地址，必须回到宿主网关，不能被 WARP 默认策略路由接走。
        PRE_DEFAULT_SRC=$(ip -o -4 addr show dev "$PRE_DEFAULT_DEV" scope global \
            | awk 'NR == 1 { split($4, addr, "/"); print addr[1] }')
        if [ -n "$PRE_DEFAULT_SRC" ]; then
            if ! ip rule show | grep -q "from ${PRE_DEFAULT_SRC} lookup main"; then
                if ip rule add pref 100 from "$PRE_DEFAULT_SRC/32" lookup main > /dev/null 2>&1; then
                    warp_log "已添加入站服务回程策略: from $PRE_DEFAULT_SRC lookup main"
                fi
            fi
        fi

        # 双栈时为容器原生 IPv6 全局地址补对称回程策略：::/0 被 wg0 接管后，
        # 来自容器 v6 地址的响应包必须走原网关而非 WARP，否则 v6 入站服务的
        # 回包会被 WARP 默认路由接走形成非对称黑洞（对应 IPv4 侧的 lookup main）。
        if is_truthy "${ENABLE_WARP_IPV6:-0}"; then
            PRE_DEFAULT_SRC_V6=$(ip -o -6 addr show dev "$PRE_DEFAULT_DEV" scope global \
                | awk 'NR == 1 { split($4, addr, "/"); print addr[1] }')
            if [ -n "$PRE_DEFAULT_SRC_V6" ]; then
                if ! ip -6 rule show | grep -q "from ${PRE_DEFAULT_SRC_V6} lookup main"; then
                    if ip -6 rule add pref 100 from "$PRE_DEFAULT_SRC_V6" lookup main > /dev/null 2>&1; then
                        warp_log "已添加 IPv6 入站服务回程策略: from $PRE_DEFAULT_SRC_V6 lookup main"
                    fi
                fi
            fi
        fi
    else
        warp_log "未检测到启动前默认网关，跳过私网绕过路由恢复"
    fi

    # 恢复 Tailscale 回程路由（如有）
    TAILSCALE_CIDR="${TAILSCALE_CIDR:-100.64.0.0/10}"
    if [ -n "$PRE_WARP_GW" ] && [ -n "$PRE_WARP_DEV" ]; then
        if ip route replace "$TAILSCALE_CIDR" via "$PRE_WARP_GW" dev "$PRE_WARP_DEV" > /dev/null 2>&1; then
            warp_log "已为 ${TAILSCALE_CIDR} 恢复回程路由"
        fi
    fi
}

# ==========================================
# WireGuard 路径 - 阶段 4：启动 MicroSOCKS
# ==========================================
start_socks() {
    warp_log "启动 MicroSOCKS 引擎，监听 ${WARP_SOCKS_BIND}:${WARP_SOCKS_PORT}"

    if [ -n "${SOCKS_USER:-}" ] && [ -n "${SOCKS_PASS:-}" ]; then
        warp_log "SOCKS5 认证已开启 (User: $SOCKS_USER)"
        microsocks -i "$WARP_SOCKS_BIND" -p "$WARP_SOCKS_PORT" \
            -u "$SOCKS_USER" -P "$SOCKS_PASS" &
    else
        # 对外监听（0.0.0.0）且未设认证时明确告警，避免变成公网开放代理（上游 1d7a482）
        if [ "$WARP_SOCKS_BIND" = "0.0.0.0" ] || [ "$WARP_SOCKS_BIND" = "::" ]; then
            echo "==> [WARP] ⚠️  WARNING: SOCKS5 对外监听 (${WARP_SOCKS_BIND}) 但未设置 SOCKS_USER/SOCKS_PASS，当前为公开访问模式！" >&2
        fi
        microsocks -i "$WARP_SOCKS_BIND" -p "$WARP_SOCKS_PORT" &
    fi

    WARP_PID=$!
    # 等待 microsocks 就绪
    sleep 1

    # 验证 microsocks 是否成功启动，避免后续误以为 WARP 已可用
    if ! kill -0 "$WARP_PID" 2>/dev/null; then
        warp_fail
    fi
}

# ==========================================
# MASQUE 路径（usque 用户态，抗 UDP QoS/封锁场景）
# 吸收自上游 8045ba9 / d71f750
# ==========================================
register_masque() {
    command -v usque >/dev/null 2>&1 || {
        echo "==> [WARP] ❌ 镜像内未找到 usque，无法使用 MASQUE 模式" >&2
        exit 1
    }

    conf_dir="$(dirname "$USQUE_CONFIG")"
    mkdir -p "$conf_dir"

    if [ -f "$USQUE_CONFIG" ] && [ -s "$USQUE_CONFIG" ]; then
        warp_log "检测到已有 MASQUE 配置: ${USQUE_CONFIG}"
        return 0
    fi

    # 删除零字节残留配置，避免 usque 误判（上游 d71f750）
    if [ -f "$USQUE_CONFIG" ] && [ ! -s "$USQUE_CONFIG" ]; then
        rm -f "$USQUE_CONFIG"
    fi

    warp_log "未检测到 MASQUE 配置，正在通过 usque 注册 Cloudflare WARP 设备..."
    # -a 接受 ToS；-n 指定设备名
    set -- usque -c "$USQUE_CONFIG" register -a
    if [ -n "$USQUE_DEVICE_NAME" ]; then
        set -- "$@" -n "$USQUE_DEVICE_NAME"
    fi
    if [ -n "$WARP_JWT" ]; then
        warp_log "使用 Zero Trust JWT 注册"
        set -- "$@" --jwt "$WARP_JWT"
    fi

    # 输出落盘以便诊断；usque 常在创建配置前打印 "Config file not found"
    reg_log="$(mktemp /tmp/usque-register.XXXXXX 2>/dev/null || echo /tmp/usque-register.log)"
    if ! (
        cd "$conf_dir" || exit 1
        "$@" > "$reg_log" 2>&1
    ); then
        cat "$reg_log" 2>/dev/null || true
        rm -f "$reg_log"
        echo "==> [WARP] ❌ usque register 失败（可能触发 Cloudflare 限流，请稍后重试并确保 volume 持久化配置）" >&2
        exit 1
    fi
    rm -f "$reg_log"

    # usque 可能把 config.json 写到 CWD —— 规范化到 USQUE_CONFIG（上游 d71f750）
    if [ ! -f "$USQUE_CONFIG" ] || [ ! -s "$USQUE_CONFIG" ]; then
        if [ -f "$conf_dir/config.json" ] && [ -s "$conf_dir/config.json" ]; then
            mv -f "$conf_dir/config.json" "$USQUE_CONFIG"
            warp_log "已将 config.json 规范为 ${USQUE_CONFIG}"
        fi
    fi

    [ -f "$USQUE_CONFIG" ] && [ -s "$USQUE_CONFIG" ] || {
        echo "==> [WARP] ❌ usque register 后未生成配置: $USQUE_CONFIG" >&2
        exit 1
    }
    warp_log "MASQUE 设备注册成功 → ${USQUE_CONFIG}"
}

# WARP+ license 尽力绑定，失败不阻断代理（上游 8045ba9）
maybe_apply_warp_license() {
    [ -n "$WARP_LICENSE" ] || return 0
    command -v usque >/dev/null 2>&1 || return 0

    warp_log "尝试绑定 WARP+ license..."
    if usque -c "$USQUE_CONFIG" license "$WARP_LICENSE" >/dev/null 2>&1; then
        warp_log "WARP+ license 已应用 (license 子命令)"
        return 0
    fi
    if usque -c "$USQUE_CONFIG" account license "$WARP_LICENSE" >/dev/null 2>&1; then
        warp_log "WARP+ license 已应用 (account license)"
        return 0
    fi
    echo "==> [WARP] ⚠️  当前 usque 构建可能不支持运行时 license 绑定；若需 WARP+ 请查阅 usque 文档或重新注册" >&2
}

start_masque_socks() {
    proxy_mode="$(normalize_masque_proxy_mode "$MASQUE_PROXY_MODE")"
    warp_log "协议: MASQUE (usque)  代理模式: ${proxy_mode}"

    # 小内存宿主机软上限 Go 堆（运行时忽略则无效果）
    if [ -n "${GOMEMLIMIT:-}" ]; then
        export GOMEMLIMIT
        warp_log "GOMEMLIMIT=${GOMEMLIMIT}"
    fi

    # 全局 -c 必须在子命令之前
    set -- usque -c "$USQUE_CONFIG" "$proxy_mode" -b "$WARP_SOCKS_BIND" -p "$WARP_SOCKS_PORT"

    if [ -n "${SOCKS_USER:-}" ] && [ -n "${SOCKS_PASS:-}" ]; then
        warp_log "SOCKS5 认证已开启 (User: $SOCKS_USER)"
        set -- "$@" -u "$SOCKS_USER" -w "$SOCKS_PASS"
    else
        if [ "$WARP_SOCKS_BIND" = "0.0.0.0" ] || [ "$WARP_SOCKS_BIND" = "::" ]; then
            echo "==> [WARP] ⚠️  WARNING: SOCKS5 对外监听 (${WARP_SOCKS_BIND}) 但未设置 SOCKS_USER/SOCKS_PASS，当前为公开访问模式！" >&2
        fi
    fi

    # HTTP/2 (TCP:443) 回退 — 仅完整 socks 模式支持，l4-socks 是 usque 限制
    if is_truthy "$MASQUE_HTTP2"; then
        if [ "$proxy_mode" = "l4-socks" ]; then
            echo "==> [WARP] ⚠️  MASQUE_HTTP2=1 但 l4-socks 不支持 --http2；请改 MASQUE_PROXY_MODE=socks，或关闭 HTTP2" >&2
        else
            warp_log "启用 MASQUE HTTP/2 (TCP) 回退"
            set -- "$@" --http2
        fi
    fi

    # IPv6 隧道开关：完整 socks 模式且 usque 构建支持 --no-tunnel-ipv6 时生效（上游 8045ba9）
    if [ "$proxy_mode" = "socks" ]; then
        if ! is_truthy "${ENABLE_WARP_IPV6:-0}"; then
            if usque socks --help 2>&1 | grep -q 'no-tunnel-ipv6'; then
                set -- "$@" --no-tunnel-ipv6
            fi
        fi
    fi

    warp_log "usque ${proxy_mode} 监听 ${WARP_SOCKS_BIND}:${WARP_SOCKS_PORT}"
    "$@" &
    usque_pid=$!
    sleep 1
    if ! kill -0 "$usque_pid" 2>/dev/null; then
        warp_fail
    fi
}

run_wireguard_path() {
    sanitize_wg_config
    start_wireguard
    start_socks
}

run_masque_path() {
    register_masque
    maybe_apply_warp_license
    start_masque_socks
}

# ==========================================
# 出口 IP 探测（经 SOCKS5 代理，数字端点避免 DNS 挂起，上游 857c7a3）
# ==========================================
detect_exit_ip() {
    _WARP_EXIT_IP=$(curl -4 -sS --connect-timeout 2 -m 5 \
        --proxy "socks5://127.0.0.1:${WARP_SOCKS_PORT}" \
        https://1.1.1.1/cdn-cgi/trace 2>/dev/null \
        | grep -oE 'ip=[0-9.]+' | cut -d= -f2 || true)

    # 双栈时追加 IPv6 出口探测；MASQUE 为用户态隧道无 wg0 网卡，不能以其作前置条件
    _WARP_EXIT_IP_V6=""
    if is_truthy "${ENABLE_WARP_IPV6:-0}"; then
        if [ "$(normalize_tunnel_protocol "$TUNNEL_PROTOCOL")" != "wireguard" ] || iface_has_global_ipv6 wg0; then
            # socks5://（本地解析）使 --resolve 映射生效；socks5h:// 会把域名
            # 交给代理端解析，本地 --resolve 被绕过，探测不再受控走 v6。
            _WARP_EXIT_IP_V6=$(curl -6 -sS --connect-timeout 2 -m 5 \
                --resolve www.cloudflare.com:443:2606:4700::11 \
                --proxy "socks5://127.0.0.1:${WARP_SOCKS_PORT}" \
                https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null \
                | grep -oE 'ip=[0-9a-f:]+' | cut -d= -f2 || true)
        fi
    fi
}

# ==========================================
# Main
# ==========================================
main() {
    mkdir -p /etc/wireguard

    proto="$(normalize_tunnel_protocol "$TUNNEL_PROTOCOL")"

    case "$proto" in
        wireguard) run_wireguard_path ;;
        masque)    run_masque_path ;;
        *)         echo "==> [WARP] ❌ 内部错误: 未处理的协议 $proto" >&2; exit 1 ;;
    esac

    warp_ok

    detect_exit_ip
    if [ -n "$_WARP_EXIT_IP" ]; then
        echo "==> [WARP] 出口 IPv4: $_WARP_EXIT_IP"
    else
        echo "==> [WARP] 出口 IPv4: 获取超时"
    fi
    if [ -n "${_WARP_EXIT_IP_V6:-}" ]; then
        echo "==> [WARP] 出口 IPv6: $_WARP_EXIT_IP_V6"
    elif is_truthy "${ENABLE_WARP_IPV6:-0}"; then
        echo "==> [WARP] 出口 IPv6: 获取超时（隧道未就绪或 wg0 无全局 v6 地址）"
    fi
}

main "$@"
