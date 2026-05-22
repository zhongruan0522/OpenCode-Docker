#!/bin/bash
# Docker 健康检查：通过 supervisorctl 确认所有关键进程均处于 RUNNING 状态。
# 任何一个进程非 RUNNING 则返回失败。
set -e

STATUS=$(supervisorctl -c /etc/supervisor/supervisord.conf status)

# 检查 opencode 和 code-server 是否都处于 RUNNING 状态
echo "$STATUS" | grep -qE '^opencode\s+RUNNING' || { echo "opencode not RUNNING"; exit 1; }
echo "$STATUS" | grep -qE '^code-server\s+RUNNING' || { echo "code-server not RUNNING"; exit 1; }
echo "$STATUS" | grep -qE '^manager\s+RUNNING' || { echo "manager not RUNNING"; exit 1; }

echo "All services healthy"
exit 0
