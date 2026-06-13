#!/bin/bash
# Docker 健康检查：通过 supervisorctl 确认所有关键进程均处于 RUNNING 状态。
# 任何一个进程非 RUNNING 则返回失败。
# SSH Server（sshd）不在 supervisord 管理下，单独检查进程是否存在。
set -e

STATUS=$(supervisorctl -c /etc/supervisor/supervisord.conf status)

# 检查 opencode、code-server 是否都处于 RUNNING 状态
echo "$STATUS" | grep -qE '^opencode\s+RUNNING' || { echo "opencode not RUNNING"; exit 1; }
echo "$STATUS" | grep -qE '^code-server\s+RUNNING' || { echo "code-server not RUNNING"; exit 1; }

# 检查 sshd（仅在 authorized_keys 存在时）
if [ -f /home/app/.ssh/authorized_keys ] && [ -s /home/app/.ssh/authorized_keys ]; then
    pgrep -x sshd >/dev/null || { echo "sshd not running"; exit 1; }
fi

echo "All services healthy"
exit 0
