#!/bin/bash
# cpu_stress_watchdog.sh
# External watchdog for cpu_stress daemon
# Deploy via crontab: * * * * * /path/to/cpu_stress_watchdog.sh
#
# 功能：检查主进程是否存活，不存活则清理PID文件

set -euo pipefail

STATE_DIR="${HOME}/.cpu_stress"
PID_FILE="${STATE_DIR}/cpu_stress.pid"
LOG_DIR="${STATE_DIR}/log"
LOG_FILE="${LOG_DIR}/cpu_stress_watchdog.log"

# 确保日志目录存在
mkdir -p "$LOG_DIR"

log_msg() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

# 检查主进程是否存活
if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$PID" ] && ! kill -0 "$PID" 2>/dev/null; then
        log_msg "[WATCHDOG] Main process $PID dead, cleaning PID file"
        rm -f "$PID_FILE"
        log_msg "[WATCHDOG] Cleanup complete"
    fi
fi

# 日志轮转（>1MB时备份）
if [ -f "$LOG_FILE" ]; then
    LOG_SIZE=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$LOG_SIZE" -gt 1048576 ] 2>/dev/null; then
        mv "$LOG_FILE" "${LOG_FILE}.1"
    fi
fi
