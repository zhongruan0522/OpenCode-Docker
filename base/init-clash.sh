#!/bin/bash
# mihomo (Clash) 初始化脚本
# 读取用户挂载的 Clash/mihomo 订阅配置，覆写 mixed-port 后启动代理
#
# 环境变量：
#   ENABLE_CLASH       1=启用
#   CLASH_CONFIG_PATH  配置文件在容器内的路径（volume 挂载）
#   CLASH_MIXED_PORT   混合代理端口（默认 7890）

set -e

MIHOMO_DIR="/etc/mihomo"
MIHOMO_CONFIG="${MIHOMO_DIR}/config.yaml"
MIHOMO_LOG="/tmp/mihomo-init.log"
CLASH_MIXED_PORT="${CLASH_MIXED_PORT:-7890}"

clash_ok()   { echo "==> [Clash] ✅ mihomo 代理启动成功"; }
clash_fail() { echo "==> [Clash] ❌ mihomo 代理启动失败 (日志: ${MIHOMO_LOG})"; exit 1; }

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

    # 3. 覆写/注入 mixed-port，保证端口一致
    if grep -qE '^mixed-port:' "${MIHOMO_CONFIG}"; then
        sed -i "s/^mixed-port:.*/mixed-port: ${CLASH_MIXED_PORT}/" "${MIHOMO_CONFIG}"
    elif grep -qE '^port:' "${MIHOMO_CONFIG}" || grep -qE '^socks-port:' "${MIHOMO_CONFIG}"; then
        # 配置使用 port/socks-port 旧格式，追加 mixed-port 统一端口
        sed -i "1a mixed-port: ${CLASH_MIXED_PORT}" "${MIHOMO_CONFIG}"
    else
        sed -i "1a mixed-port: ${CLASH_MIXED_PORT}" "${MIHOMO_CONFIG}"
    fi

    # 4. 启动 mihomo（后台守护，日志落盘）
    echo "==> [Clash] mihomo 启动中 (配置: ${CLASH_CONFIG_PATH} → ${MIHOMO_CONFIG}, 端口: ${CLASH_MIXED_PORT})"
    mihomo -d "${MIHOMO_DIR}" -f "${MIHOMO_CONFIG}" > "${MIHOMO_LOG}" 2>&1 &
    local pid=$!

    # 5. 等待代理就绪（最多 15 秒）
    local i=0
    while [ $i -lt 15 ]; do
        if curl -sS --connect-timeout 1 -m 3 \
            --proxy "socks5://127.0.0.1:${CLASH_MIXED_PORT}" \
            https://1.1.1.1/cdn-cgi/trace > /dev/null 2>&1; then
            break
        fi
        if ! kill -0 "$pid" 2>/dev/null; then
            clash_fail
        fi
        sleep 1
        i=$((i + 1))
    done

    if [ $i -ge 15 ]; then
        echo "==> [Clash] ⚠️  代理就绪探测超时（mihomo 进程仍在运行）" >&2
    fi

    # 6. 探测出口 IP
    local exit_ip
    exit_ip=$(curl -4 -sS --connect-timeout 3 -m 5 \
        --proxy "socks5://127.0.0.1:${CLASH_MIXED_PORT}" \
        https://1.1.1.1/cdn-cgi/trace 2>/dev/null \
        | grep -oE 'ip=[0-9.]+' | cut -d= -f2 || true)

    if [ -n "${exit_ip}" ]; then
        echo "==> [Clash] 出口 IP: ${exit_ip}"
    else
        echo "==> [Clash] 出口 IP: 获取超时"
    fi

    clash_ok
}

main "$@"
