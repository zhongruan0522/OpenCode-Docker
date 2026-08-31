#!/bin/bash
# mihomo (Clash) TUN 模式初始化脚本
# 创建 TUN 设备接管容器内所有出站流量，进程无需读代理环境变量即可被代理
#
# 环境变量：
#   ENABLE_CLASH       1=启用
#   CLASH_CONFIG_PATH  配置文件在容器内的路径（volume 挂载）

set -e

MIHOMO_DIR="/etc/mihomo"
MIHOMO_CONFIG="${MIHOMO_DIR}/config.yaml"
MIHOMO_LOG="/tmp/mihomo-init.log"

clash_ok()   { echo "==> [Clash] ✅ mihomo TUN 模式启动成功"; }
clash_fail() { echo "==> [Clash] ❌ mihomo TUN 模式启动失败 (日志: ${MIHOMO_LOG})"; exit 1; }

main() {
    # 1. 校验配置文件路径
    if [ -z "${CLASH_CONFIG_PATH:-}" ]; then
        echo "==> [Clash] ❌ CLASH_CONFIG_PATH 未设置，无法启动 mihomo" >&2
        exit 1
    fi
    if [ ! -f "${CLASH_CONFIG_PATH}" ]; then
        echo "==> [Clash] ❌ 配置文件不存在: ${CLASH_CONFIG_PATH}" >&2
        exit 1
    fi

    # 2. 先删旧配置再复制新配置，避免旧文件残留导致节点不更新
    mkdir -p "${MIHOMO_DIR}"
    rm -f "${MIHOMO_CONFIG}"
    cp "${CLASH_CONFIG_PATH}" "${MIHOMO_CONFIG}"

    # 3. 用 PyYAML 强制覆写 TUN + DNS 配置（保证 TUN 模式生效）
    if ! python3 - "${MIHOMO_CONFIG}" <<'PYEOF'
import sys, yaml

config_path = sys.argv[1]
with open(config_path, 'r', encoding='utf-8') as f:
    config = yaml.safe_load(f) or {}

# 强制 TUN 模式：接管所有出站流量
config['tun'] = {
    'enable': True,
    'stack': 'system',
    'device': 'Meta',
    'auto-route': True,
    'auto-detect-interface': True,
    'dns-hijack': ['any:53'],
}

# 确保 DNS 开启（TUN fake-ip 依赖 DNS 模块）
if not isinstance(config.get('dns'), dict):
    config['dns'] = {}
config['dns']['enable'] = True
config['dns'].setdefault('enhanced-mode', 'fake-ip')
config['dns'].setdefault('fake-ip-range', '198.18.0.1/16')
config['dns'].setdefault(
    'nameserver',
    ['https://doh.pub/dns-query', 'https://dns.alidns.com/dns-query'],
)

with open(config_path, 'w', encoding='utf-8') as f:
    yaml.dump(config, f, allow_unicode=True, default_flow_style=False, sort_keys=False)
PYEOF
    then
        echo "==> [Clash] ❌ 配置文件解析失败（YAML 格式错误？）: ${CLASH_CONFIG_PATH}" >&2
        exit 1
    fi

    # 4. 确保 TUN 设备节点存在（privileged 容器内 mknod）
    if [ ! -c /dev/net/tun ]; then
        mkdir -p /dev/net
        mknod /dev/net/tun c 10 200
        chmod 600 /dev/net/tun
    fi

    # 5. 启动 mihomo（TUN + auto-route 由 mihomo 自动接管路由）
    echo "==> [Clash] mihomo TUN 模式启动中 (配置: ${CLASH_CONFIG_PATH} → ${MIHOMO_CONFIG})"
    mihomo -d "${MIHOMO_DIR}" -f "${MIHOMO_CONFIG}" > "${MIHOMO_LOG}" 2>&1 &
    local pid=$!

    # 6. 等待 TUN 设备出现（mihomo 默认设备名 Meta）
    local i=0
    while [ "$i" -lt 15 ]; do
        if ip link show Meta > /dev/null 2>&1; then
            break
        fi
        if ! kill -0 "$pid" 2>/dev/null; then
            clash_fail
        fi
        sleep 1
        i=$((i + 1))
    done

    if [ "$i" -ge 15 ]; then
        echo "==> [Clash] ⚠️  TUN 设备未在 15 秒内出现（mihomo 进程仍在运行，继续等待）" >&2
    fi

    # 7. 验证出站流量确实经过 TUN（直接 curl 不带 proxy 参数）
    sleep 3
    local exit_ip
    exit_ip=$(curl -4 -sS --connect-timeout 5 -m 10 \
        https://1.1.1.1/cdn-cgi/trace 2>/dev/null \
        | grep -oE 'ip=[0-9.]+' | cut -d= -f2 || true)

    if [ -n "${exit_ip}" ]; then
        echo "==> [Clash] 出口 IP: ${exit_ip}（经 TUN 设备 Meta）"
    else
        echo "==> [Clash] 出口 IP: 获取超时"
    fi

    clash_ok
}

main "$@"
