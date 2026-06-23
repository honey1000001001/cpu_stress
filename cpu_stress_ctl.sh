#!/bin/bash
# cpu_stress_ctl.sh - CPU加压守护进程控制脚本
# 生产级控制界面，用于管理cpu_stress.py

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STRESS_SCRIPT="${SCRIPT_DIR}/cpu_stress.py"
WATCHDOG_SCRIPT="${SCRIPT_DIR}/cpu_stress_watchdog.sh"
STATE_DIR="${HOME}/.cpu_stress"
PID_FILE="${STATE_DIR}/cpu_stress.pid"
LOCK_FILE="${STATE_DIR}/cpu_stress.lock"
LOG_DIR="${STATE_DIR}/log"
LOG_FILE="${LOG_DIR}/cpu_stress.log"
WATCHDOG_LOG="${LOG_DIR}/cpu_stress_watchdog.log"
QUOTA_FILE="${STATE_DIR}/quota.json"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ======================== 辅助函数 ========================
print_header() {
    clear
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}      CPU加压守护进程控制面板${NC}"
    echo -e "${CYAN}         v1.0.0 生产版${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo ""
}

print_status() {
    local status="${1:-}"
    local msg="${2:-}"
    case "$status" in
        ok)    echo -e "  ${GREEN}[正常]${NC} $msg" ;;
        warn)  echo -e "  ${YELLOW}[警告]${NC} $msg" ;;
        error) echo -e "  ${RED}[错误]${NC} $msg" ;;
        info)  echo -e "  ${BLUE}[信息]${NC} $msg" ;;
    esac
}

check_running() {
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

get_pid() {
    if [ -f "$PID_FILE" ]; then
        cat "$PID_FILE" 2>/dev/null
    fi
}

check_script() {
    if [ ! -f "$STRESS_SCRIPT" ]; then
        print_status "error" "未找到cpu_stress.py: $STRESS_SCRIPT"
        return 1
    fi
    return 0
}

wait_for_stop() {
    local timeout=15
    local count=0
    while check_running && [ $count -lt $timeout ]; do
        sleep 1
        count=$((count + 1))
    done
    if check_running; then
        print_status "warn" "进程仍在运行，超过${timeout}秒，强制终止"
        kill -9 $(get_pid) 2>/dev/null || true
        sleep 1
    fi
    rm -f "$PID_FILE" 2>/dev/null
}

# ======================== 核心操作 ========================
do_start() {
    print_header
    echo -e "${BLUE}=== 启动CPU加压守护进程 ===${NC}"
    echo ""

    if ! check_script; then
        return 1
    fi

    if check_running; then
        print_status "warn" "守护进程已在运行 (PID=$(get_pid))"
        return 0
    fi

    # 初始化默认值
    local target=40
    local k8s_enabled="auto"
    local eviction_check="auto"
    local quota=6
    local interval=2
    local max_workers=""
    local mem_limit=256
    local watchdog_enabled="auto"
    local verbose=""

    # 检测K8s可用性
    local k8s_available=false
    if command -v kubectl &>/dev/null && sudo -n kubectl get nodes &>/dev/null 2>&1; then
        k8s_available=true
    fi

    while true; do
        print_header
        echo -e "${BLUE}=== 启动CPU加压守护进程 ===${NC}"
        echo ""
        echo -e "${CYAN}当前配置:${NC}"
        echo ""
        echo -e "  [1] 目标水位:        ${GREEN}${target}%${NC}"
        if [ "$k8s_enabled" = "auto" ]; then
            if $k8s_available; then
                echo -e "  [2] K8s保护:         ${GREEN}自动(已检测到kubectl)${NC}"
            else
                echo -e "  [2] K8s保护:         ${YELLOW}自动(kubectl不可用)${NC}"
            fi
        elif [ "$k8s_enabled" = "on" ]; then
            echo -e "  [2] K8s保护:         ${GREEN}强制开启${NC}"
        else
            echo -e "  [2] K8s保护:         ${YELLOW}强制关闭${NC}"
        fi
        if [ "$eviction_check" = "auto" ]; then
            echo -e "  [3] 驱逐检查:        ${GREEN}自动${NC}"
        elif [ "$eviction_check" = "on" ]; then
            echo -e "  [3] 驱逐检查:        ${GREEN}开启${NC}"
        else
            echo -e "  [3] 驱逐检查:        ${YELLOW}关闭${NC}"
        fi
        echo -e "  [4] 月度配额:        ${GREEN}${quota}%${NC}"
        echo -e "  [5] 监控间隔:        ${GREEN}${interval}秒${NC}"
        if [ -n "$max_workers" ]; then
            echo -e "  [6] 最大worker数:    ${GREEN}${max_workers}${NC}"
        else
            echo -e "  [6] 最大worker数:    ${GREEN}自动(核心数/2)${NC}"
        fi
        echo -e "  [7] 内存限制:        ${GREEN}${mem_limit}MB${NC}"
        if [ "$watchdog_enabled" = "auto" ]; then
            echo -e "  [8] 看门狗:          ${GREEN}自动(推荐开启)${NC}"
        elif [ "$watchdog_enabled" = "on" ]; then
            echo -e "  [8] 看门狗:          ${GREEN}开启${NC}"
        else
            echo -e "  [8] 看门狗:          ${YELLOW}关闭${NC}"
        fi
        if [ "$verbose" = "on" ]; then
            echo -e "  [9] 详细日志:        ${GREEN}开启${NC}"
        else
            echo -e "  [9] 详细日志:        ${YELLOW}关闭${NC}"
        fi
        echo ""
        echo -e "${CYAN}  [s]  确认启动${NC}"
        echo -e "${CYAN}  [r]  恢复默认${NC}"
        echo -e "${CYAN}  [0]  取消${NC}"
        echo ""
        read -p "请选择要修改的选项: " choice

        case $choice in
            1)
                echo ""
                read -p "输入目标水位 (0-100, 默认40): " input
                if [ -n "$input" ] && [[ "$input" =~ ^[0-9]+$ ]] && [ "$input" -ge 0 ] && [ "$input" -le 100 ]; then
                    target=$input
                    print_status "ok" "目标水位设置为 ${target}%"
                elif [ -z "$input" ]; then
                    target=40
                    print_status "info" "使用默认值 40%"
                else
                    print_status "error" "无效输入，保持当前值"
                fi
                sleep 1
                ;;
            2)
                echo ""
                echo "K8s保护选项:"
                echo "  1) 自动 (推荐) - 根据kubectl可用性自动决定"
                echo "  2) 强制开启    - 需要kubectl可用"
                echo "  3) 强制关闭    - 不检查K8s状态"
                read -p "请选择 [1-3]: " k8s_choice
                case $k8s_choice in
                    1) k8s_enabled="auto" ;;
                    2) k8s_enabled="on" ;;
                    3) k8s_enabled="off" ;;
                    *) print_status "error" "无效选择" ;;
                esac
                sleep 1
                ;;
            3)
                echo ""
                echo "驱逐压力检查选项:"
                echo "  1) 自动 (推荐) - 跟随K8s保护设置"
                echo "  2) 强制开启    - 始终检查驱逐压力"
                echo "  3) 强制关闭    - 不检查驱逐压力"
                read -p "请选择 [1-3]: " evict_choice
                case $evict_choice in
                    1) eviction_check="auto" ;;
                    2) eviction_check="on" ;;
                    3) eviction_check="off" ;;
                    *) print_status "error" "无效选择" ;;
                esac
                sleep 1
                ;;
            4)
                echo ""
                read -p "输入月度配额 (0-100, 默认6): " input
                if [ -n "$input" ] && [[ "$input" =~ ^[0-9]+$ ]] && [ "$input" -ge 0 ] && [ "$input" -le 100 ]; then
                    quota=$input
                    print_status "ok" "月度配额设置为 ${quota}%"
                elif [ -z "$input" ]; then
                    quota=6
                    print_status "info" "使用默认值 6%"
                else
                    print_status "error" "无效输入，保持当前值"
                fi
                sleep 1
                ;;
            5)
                echo ""
                read -p "输入监控间隔秒数 (1-60, 默认2): " input
                if [ -n "$input" ] && [[ "$input" =~ ^[0-9]+$ ]] && [ "$input" -ge 1 ] && [ "$input" -le 60 ]; then
                    interval=$input
                    print_status "ok" "监控间隔设置为 ${interval}秒"
                elif [ -z "$input" ]; then
                    interval=2
                    print_status "info" "使用默认值 2秒"
                else
                    print_status "error" "无效输入，保持当前值"
                fi
                sleep 1
                ;;
            6)
                echo ""
                read -p "输入最大worker数 (0=自动, 默认自动): " input
                if [ -n "$input" ] && [[ "$input" =~ ^[0-9]+$ ]]; then
                    if [ "$input" -eq 0 ]; then
                        max_workers=""
                        print_status "info" "使用自动值"
                    else
                        max_workers=$input
                        print_status "ok" "最大worker数设置为 ${max_workers}"
                    fi
                elif [ -z "$input" ]; then
                    max_workers=""
                    print_status "info" "使用自动值"
                else
                    print_status "error" "无效输入，保持当前值"
                fi
                sleep 1
                ;;
            7)
                echo ""
                read -p "输入内存限制MB (64-1024, 默认256): " input
                if [ -n "$input" ] && [[ "$input" =~ ^[0-9]+$ ]] && [ "$input" -ge 64 ] && [ "$input" -le 1024 ]; then
                    mem_limit=$input
                    print_status "ok" "内存限制设置为 ${mem_limit}MB"
                elif [ -z "$input" ]; then
                    mem_limit=256
                    print_status "info" "使用默认值 256MB"
                else
                    print_status "error" "无效输入，保持当前值"
                fi
                sleep 1
                ;;
            8)
                echo ""
                echo "看门狗选项 (独立进程监控主循环心跳):"
                echo "  1) 自动 (推荐) - 始终开启"
                echo "  2) 开启        - 启用看门狗保护"
                echo "  3) 关闭        - 不使用看门狗"
                read -p "请选择 [1-3]: " wd_choice
                case $wd_choice in
                    1) watchdog_enabled="auto" ;;
                    2) watchdog_enabled="on" ;;
                    3) watchdog_enabled="off" ;;
                    *) print_status "error" "无效选择" ;;
                esac
                sleep 1
                ;;
            9)
                echo ""
                if [ "$verbose" = "on" ]; then
                    verbose=""
                    print_status "info" "详细日志已关闭"
                else
                    verbose="on"
                    print_status "info" "详细日志已开启"
                fi
                sleep 1
                ;;
            s|S)
                break
                ;;
            r|R)
                target=40
                k8s_enabled="auto"
                eviction_check="auto"
                quota=6
                interval=2
                max_workers=""
                mem_limit=256
                watchdog_enabled="auto"
                verbose=""
                print_status "ok" "已恢复默认配置"
                sleep 1
                ;;
            0)
                return 0
                ;;
            *)
                print_status "error" "无效选项"
                sleep 1
                ;;
        esac
    done

    # 构建启动命令数组（安全方式，不用eval）
    local cmd_array=("python3" "$STRESS_SCRIPT")
    cmd_array+=("--target" "$target")
    cmd_array+=("--quota" "$quota")
    cmd_array+=("--interval" "$interval")
    cmd_array+=("--mem-limit" "$mem_limit")
    cmd_array+=("--daemon")
    cmd_array+=("--log-file" "$LOG_FILE")

    # K8s保护
    case $k8s_enabled in
        auto)
            if $k8s_available; then
                cmd_array+=("--protect-k8s")
            else
                cmd_array+=("--no-protect-k8s")
            fi
            ;;
        on)  cmd_array+=("--protect-k8s") ;;
        off) cmd_array+=("--no-protect-k8s") ;;
    esac

    # 驱逐检查
    case $eviction_check in
        auto)
            if [ "$k8s_enabled" = "off" ]; then
                cmd_array+=("--no-check-eviction")
            else
                cmd_array+=("--check-eviction")
            fi
            ;;
        on)  cmd_array+=("--check-eviction") ;;
        off) cmd_array+=("--no-check-eviction") ;;
    esac

    # 最大worker数
    if [ -n "$max_workers" ]; then
        cmd_array+=("--max-workers" "$max_workers")
    fi

    # 看门狗
    case $watchdog_enabled in
        auto|on) cmd_array+=("--watchdog") ;;
        off)     cmd_array+=("--no-watchdog") ;;
    esac

    # 详细日志
    if [ "$verbose" = "on" ]; then
        cmd_array+=("--verbose")
    fi

    # 从配置文件读取额外参数（严格校验）
    if [ -f "${STATE_DIR}/config" ]; then
        local config_content
        config_content=$(cat "${STATE_DIR}/config" 2>/dev/null)
        # 严格校验：每行必须是 --xxx=yyy 或 --xxx yyy 格式
        while IFS= read -r line; do
            # 跳过空行和注释
            [[ -z "$line" || "$line" =~ ^# ]] && continue
            # 校验格式：只允许 --开头的参数名 + 等号或空格 + 数值/字符串
            if [[ "$line" =~ ^--[a-zA-Z][-a-zA-Z0-9]*(=[a-zA-Z0-9._/-]+|[[:space:]]+[a-zA-Z0-9._/-]+)$ ]]; then
                # 安全的参数，添加到数组
                cmd_array+=($line)
            else
                print_status "error" "配置文件包含非法参数: $line"
                return 1
            fi
        done <<< "$config_content"
    fi

    # 构建显示用的命令字符串
    local display_cmd="${cmd_array[*]}"

    # 确认启动
    print_header
    echo -e "${BLUE}=== 确认启动参数 ===${NC}"
    echo ""
    echo -e "${CYAN}将使用以下配置启动:${NC}"
    echo ""
    echo -e "  目标水位:       ${target}%"
    echo -e "  K8s保护:        $([ "$k8s_enabled" = "off" ] && echo "关闭" || echo "开启")"
    echo -e "  驱逐检查:       $([ "$eviction_check" = "off" ] && echo "关闭" || echo "开启")"
    echo -e "  月度配额:       ${quota}%"
    echo -e "  监控间隔:       ${interval}秒"
    echo -e "  最大worker:     $([ -n "$max_workers" ] && echo "${max_workers}个" || echo "自动")"
    echo -e "  内存限制:       ${mem_limit}MB"
    echo -e "  看门狗:         $([ "$watchdog_enabled" = "off" ] && echo "关闭" || echo "开启")"
    echo -e "  详细日志:       $([ "$verbose" = "on" ] && echo "开启" || echo "关闭")"
    echo ""
    echo -e "${YELLOW}执行命令: ${display_cmd}${NC}"
    echo ""
    read -p "确认启动? (y/n): " confirm
    if [ "$confirm" != "y" ]; then
        print_status "warn" "已取消启动"
        return 0
    fi

    # 启动守护进程（使用数组直接执行，不用eval）
    "${cmd_array[@]}"
    sleep 2

    if check_running; then
        print_status "ok" "守护进程启动成功 (PID=$(get_pid))"
        echo ""
        echo -e "${GREEN}日志文件: ${LOG_FILE}${NC}"
        echo -e "${GREEN}状态目录: ${STATE_DIR}${NC}"
        echo ""
        echo -e "${YELLOW}管理命令:${NC}"
        echo -e "  停止: $0 stop"
        echo -e "  状态: $0 status"
        echo -e "  日志: $0 log"
    else
        print_status "error" "守护进程启动失败"
        echo ""
        echo -e "${YELLOW}请查看日志: tail -50 ${LOG_FILE}${NC}"
        return 1
    fi
}

do_stop() {
    print_header
    echo -e "${BLUE}=== 停止CPU加压守护进程 ===${NC}"
    echo ""

    if ! check_running; then
        print_status "warn" "守护进程未运行"
        return 0
    fi

    local pid=$(get_pid)

    # 显示将要执行的命令
    echo -e "${YELLOW}将要执行以下操作:${NC}"
    echo ""
    echo -e "  ${CYAN}1. 停止守护进程 (PID=$pid)${NC}"
    echo -e "     命令: kill -TERM $pid"
    echo ""
    echo -e "  ${CYAN}2. 等待进程退出 (最多15秒)${NC}"
    echo ""
    echo -e "  ${CYAN}3. 如超时则强制终止${NC}"
    echo -e "     命令: kill -9 $pid"
    echo ""
    echo -e "  ${CYAN}4. 清理PID文件${NC}"
    echo -e "     命令: rm -f $PID_FILE"
    echo ""
    echo -e "${YELLOW}影响: 守护进程将停止运行，所有worker进程将被终止${NC}"
    echo ""
    read -p "确认停止? (y/n): " confirm
    if [ "$confirm" != "y" ]; then
        print_status "warn" "已取消停止操作"
        return 0
    fi

    echo ""
    print_status "info" "向PID=$pid发送SIGTERM信号"
    kill -TERM "$pid" 2>/dev/null

    print_status "info" "等待优雅关闭..."
    wait_for_stop

    if [ ! -f "$PID_FILE" ]; then
        print_status "ok" "守护进程停止成功"
    else
        print_status "error" "守护进程停止失败"
        return 1
    fi
}

do_restart() {
    print_header
    echo -e "${BLUE}=== 重启CPU加压守护进程 ===${NC}"
    echo ""

    if ! check_running; then
        print_status "warn" "守护进程未运行，将执行启动"
        do_start "$@"
        return $?
    fi

    local pid=$(get_pid)

    # 显示将要执行的命令
    echo -e "${YELLOW}将要执行以下操作:${NC}"
    echo ""
    echo -e "  ${CYAN}步骤1: 停止当前守护进程${NC}"
    echo -e "     命令: kill -TERM $pid"
    echo -e "     等待进程退出..."
    echo ""
    echo -e "  ${CYAN}步骤2: 启动新守护进程${NC}"
    echo -e "     将进入启动配置界面"
    echo ""
    echo -e "${YELLOW}影响: 守护进程将短暂中断后重新启动${NC}"
    echo ""
    read -p "确认重启? (y/n): " confirm
    if [ "$confirm" != "y" ]; then
        print_status "warn" "已取消重启操作"
        return 0
    fi

    do_stop
    sleep 2
    do_start "$@"
}

do_status() {
    print_header
    echo -e "${BLUE}=== 守护进程状态 ===${NC}"
    echo ""

    # 检查脚本
    if [ ! -f "$STRESS_SCRIPT" ]; then
        print_status "error" "未找到cpu_stress.py"
        return 1
    fi
    print_status "ok" "脚本: $STRESS_SCRIPT"

    # 检查运行状态
    if check_running; then
        local pid=$(get_pid)
        print_status "ok" "状态: 运行中 (PID=$pid)"

        # 获取进程信息
        if [ -f "/proc/$pid/status" ]; then
            local mem=$(grep VmRSS /proc/$pid/status 2>/dev/null | awk '{print $2/1024 " MB"}')
            print_status "info" "内存: $mem"
        fi
    else
        print_status "warn" "状态: 未运行"
    fi

    # 检查状态目录
    if [ -d "$STATE_DIR" ]; then
        print_status "ok" "状态目录: $STATE_DIR"
    else
        print_status "warn" "状态目录不存在"
    fi

    # 检查配额
    if [ -f "$QUOTA_FILE" ]; then
        local used=$(python3 -c "import json; d=json.load(open('$QUOTA_FILE')); print(f\"{d.get('used_seconds', 0)/3600:.1f}小时\")" 2>/dev/null || echo "未知")
        local remaining=$(python3 -c "import json; d=json.load(open('$QUOTA_FILE')); r=2592-d.get('used_seconds', 0); print(f\"{r/60:.1f}分钟\")" 2>/dev/null || echo "未知")
        print_status "info" "已用配额: $used, 剩余: $remaining"
    else
        print_status "warn" "配额文件不存在"
    fi

    # 检查日志文件
    if [ -f "$LOG_FILE" ]; then
        local log_size=$(wc -c < "$LOG_FILE" 2>/dev/null || echo "0")
        local log_lines=$(wc -l < "$LOG_FILE" 2>/dev/null || echo "0")
        print_status "info" "日志: ${log_size}字节, ${log_lines}行"
    else
        print_status "warn" "日志文件不存在"
    fi

    # 检查看门狗
    if crontab -l 2>/dev/null | grep -q "cpu_stress_watchdog"; then
        print_status "ok" "看门狗: 已启用"
    else
        print_status "warn" "看门狗: 未配置"
    fi
}

do_adjust_target() {
    print_header
    echo -e "${BLUE}=== 调整目标水位 ===${NC}"
    echo ""

    if ! check_running; then
        print_status "error" "守护进程未运行"
        return 1
    fi

    local current_target=$(grep "Target:" "$LOG_FILE" 2>/dev/null | tail -1 | grep -oP 'Target: \K[0-9]+' || echo "未知")
    local pid=$(get_pid)

    echo -e "当前目标: ${current_target}%"
    echo -e "守护进程PID: ${pid}"
    echo ""
    echo "操作选项:"
    echo "  1) 增加10%"
    echo "  2) 减少10%"
    echo "  3) 自定义目标值"
    echo "  0) 取消"
    echo ""
    read -p "请选择: " choice

    case $choice in
        1)
            echo ""
            echo -e "${YELLOW}将要执行: kill -USR1 $pid${NC}"
            echo -e "${YELLOW}效果: 目标水位 +10%${NC}"
            read -p "确认调整? (y/n): " confirm
            if [ "$confirm" != "y" ]; then
                print_status "warn" "已取消调整"
                return 0
            fi
            kill -USR1 "$pid" 2>/dev/null
            print_status "ok" "已发送SIGUSR1 (目标+10%)"
            ;;
        2)
            echo ""
            echo -e "${YELLOW}将要执行: kill -USR2 $pid${NC}"
            echo -e "${YELLOW}效果: 目标水位 -10%${NC}"
            read -p "确认调整? (y/n): " confirm
            if [ "$confirm" != "y" ]; then
                print_status "warn" "已取消调整"
                return 0
            fi
            kill -USR2 "$pid" 2>/dev/null
            print_status "ok" "已发送SIGUSR2 (目标-10%)"
            ;;
        3)
            read -p "输入新目标值 (0-100): " new_target
            if [[ "$new_target" =~ ^[0-9]+$ ]] && [ "$new_target" -ge 0 ] && [ "$new_target" -le 100 ]; then
                local delta=$((new_target - current_target))
                local signal_count=0
                if [ $delta -gt 0 ]; then
                    signal_count=$((delta / 10))
                elif [ $delta -lt 0 ]; then
                    signal_count=$((-delta / 10))
                fi
                echo ""
                echo -e "${YELLOW}将要执行以下操作:${NC}"
                if [ $delta -gt 0 ]; then
                    echo -e "  发送 ${signal_count} 次 SIGUSR1 信号 (每次+10%)"
                    echo -e "  命令: kill -USR1 $pid (重复${signal_count}次)"
                elif [ $delta -lt 0 ]; then
                    echo -e "  发送 ${signal_count} 次 SIGUSR2 信号 (每次-10%)"
                    echo -e "  命令: kill -USR2 $pid (重复${signal_count}次)"
                else
                    echo -e "  无变化，无需调整"
                fi
                echo -e "  效果: 目标从 ${current_target}% 调整至 ~${new_target}%"
                echo ""
                read -p "确认调整? (y/n): " confirm
                if [ "$confirm" != "y" ]; then
                    print_status "warn" "已取消调整"
                    return 0
                fi
                if [ $delta -gt 0 ]; then
                    for ((i=0; i<signal_count; i++)); do
                        kill -USR1 "$pid" 2>/dev/null
                        sleep 0.5
                    done
                elif [ $delta -lt 0 ]; then
                    for ((i=0; i<signal_count; i++)); do
                        kill -USR2 "$pid" 2>/dev/null
                        sleep 0.5
                    done
                fi
                print_status "ok" "目标已调整至 ~${new_target}%"
            else
                print_status "error" "目标值无效"
            fi
            ;;
        0)
            return 0
            ;;
        *)
            print_status "error" "无效选项"
            ;;
    esac
}

do_view_log() {
    print_header
    echo -e "${BLUE}=== 查看日志 ===${NC}"
    echo ""

    if [ ! -f "$LOG_FILE" ]; then
        print_status "warn" "日志文件不存在: $LOG_FILE"
        return 1
    fi

    echo "查看方式:"
    echo "  1) 查看最后50行"
    echo "  2) 查看最后100行"
    echo "  3) 实时跟踪"
    echo "  4) 搜索错误"
    echo "  5) 查看完整日志"
    echo "  0) 返回"
    echo ""
    read -p "请选择: " choice

    case $choice in
        1)
            echo ""
            tail -50 "$LOG_FILE"
            ;;
        2)
            echo ""
            tail -100 "$LOG_FILE"
            ;;
        3)
            echo ""
            echo -e "${YELLOW}按 Ctrl+C 停止跟踪${NC}"
            tail -f "$LOG_FILE"
            ;;
        4)
            echo ""
            grep -E "ERROR|FATAL|WARN" "$LOG_FILE" | tail -50
            ;;
        5)
            echo ""
            less "$LOG_FILE"
            ;;
        0)
            return 0
            ;;
        *)
            print_status "error" "无效选项"
            ;;
    esac
}

do_deploy_watchdog() {
    print_header
    echo -e "${BLUE}=== 部署看门狗 ===${NC}"
    echo ""

    if [ ! -f "$WATCHDOG_SCRIPT" ]; then
        print_status "error" "未找到看门狗脚本: $WATCHDOG_SCRIPT"
        return 1
    fi

    chmod +x "$WATCHDOG_SCRIPT"

    # 检查是否已部署
    if crontab -l 2>/dev/null | grep -q "cpu_stress_watchdog"; then
        print_status "warn" "看门狗已在crontab中"
        echo ""
        echo -e "${YELLOW}将要执行以下操作:${NC}"
        echo ""
        echo -e "  ${CYAN}1. 移除旧的看门狗条目${NC}"
        echo -e "     命令: crontab -l | grep -v cpu_stress_watchdog | crontab -"
        echo ""
        echo -e "  ${CYAN}2. 添加新的看门狗条目${NC}"
        echo -e "     命令: (crontab -l; echo '* * * * * $WATCHDOG_SCRIPT') | crontab -"
        echo ""
        read -p "重新部署? (y/n): " confirm
        if [ "$confirm" != "y" ]; then
            return 0
        fi
        # 移除旧条目
        crontab -l 2>/dev/null | grep -v "cpu_stress_watchdog" | crontab -
    fi

    # 显示将要执行的命令
    echo ""
    echo -e "${YELLOW}将要执行以下操作:${NC}"
    echo ""
    echo -e "  ${CYAN}添加看门狗到crontab${NC}"
    echo -e "     命令: (crontab -l 2>/dev/null; echo '* * * * * $WATCHDOG_SCRIPT') | crontab -"
    echo ""
    echo -e "  ${CYAN}效果: 每分钟自动检查守护进程是否存活${NC}"
    echo ""
    read -p "确认部署? (y/n): " confirm
    if [ "$confirm" != "y" ]; then
        print_status "warn" "已取消部署"
        return 0
    fi

    # 添加到crontab
    (crontab -l 2>/dev/null; echo "* * * * * ${WATCHDOG_SCRIPT}") | crontab -

    if crontab -l 2>/dev/null | grep -q "cpu_stress_watchdog"; then
        print_status "ok" "看门狗部署成功"
        print_status "info" "通过crontab每分钟执行"
        print_status "info" "日志: $WATCHDOG_LOG"
    else
        print_status "error" "看门狗部署失败"
        return 1
    fi
}

do_remove_watchdog() {
    print_header
    echo -e "${BLUE}=== 移除看门狗 ===${NC}"
    echo ""

    if ! crontab -l 2>/dev/null | grep -q "cpu_stress_watchdog"; then
        print_status "warn" "crontab中未找到看门狗"
        return 0
    fi

    # 显示将要执行的命令
    echo -e "${YELLOW}将要执行以下操作:${NC}"
    echo ""
    echo -e "  ${CYAN}从crontab移除看门狗条目${NC}"
    echo -e "     命令: crontab -l | grep -v cpu_stress_watchdog | crontab -"
    echo ""
    echo -e "  ${CYAN}影响: 外部看门狗将停止运行，不再自动清理残留worker${NC}"
    echo ""
    read -p "确认移除? (y/n): " confirm
    if [ "$confirm" != "y" ]; then
        print_status "warn" "已取消移除操作"
        return 0
    fi

    crontab -l 2>/dev/null | grep -v "cpu_stress_watchdog" | crontab -

    if ! crontab -l 2>/dev/null | grep -q "cpu_stress_watchdog"; then
        print_status "ok" "看门狗已从crontab移除"
    else
        print_status "error" "看门狗移除失败"
        return 1
    fi
}

do_view_quota() {
    print_header
    echo -e "${BLUE}=== 配额状态 ===${NC}"
    echo ""

    if [ ! -f "$QUOTA_FILE" ]; then
        print_status "warn" "配额文件不存在"
        return 1
    fi

    echo -e "${CYAN}当前配额信息:${NC}"
    python3 -c "
import json
from datetime import datetime

with open('$QUOTA_FILE') as f:
    data = json.load(f)

month = data.get('month', '未知')
used = data.get('used_seconds', 0)
last_update = data.get('last_update', '未知')

total_window = 720 * 3600  # 30天（秒）
quota_percent = 6
quota_seconds = total_window * quota_percent / 100
remaining = max(0, quota_seconds - used)

print(f'  月份:          {month}')
print(f'  已用:          {used/3600:.2f} 小时 ({used/60:.1f} 分钟)')
print(f'  剩余:          {remaining/3600:.2f} 小时 ({remaining/60:.1f} 分钟)')
print(f'  配额 ({quota_percent}%):   {quota_seconds/3600:.2f} 小时')
print(f'  使用率:        {used/quota_seconds*100:.1f}%')
print(f'  最后更新:      {last_update}')
"
    echo ""
}

do_save_config() {
    print_header
    echo -e "${BLUE}=== 保存配置 ===${NC}"
    echo ""

    mkdir -p "$STATE_DIR"

    echo "配置将保存到: ${STATE_DIR}/config"
    echo ""
    echo "请输入参数（按回车使用默认值）:"
    echo ""

    read -p "目标CPU水位% [40]: " target
    target=${target:-40}
    # 校验：必须是数字
    if ! [[ "$target" =~ ^[0-9]+$ ]]; then
        print_status "error" "目标水位必须是数字"
        return 1
    fi

    read -p "监控间隔秒 [2]: " interval
    interval=${interval:-2}
    if ! [[ "$interval" =~ ^[0-9]+$ ]]; then
        print_status "error" "监控间隔必须是数字"
        return 1
    fi

    read -p "最大worker数 [自动]: " max_workers
    max_workers_arg=""
    if [ -n "$max_workers" ]; then
        if ! [[ "$max_workers" =~ ^[0-9]+$ ]]; then
            print_status "error" "最大worker数必须是数字"
            return 1
        fi
        max_workers_arg="--max-workers $max_workers"
    fi

    read -p "月度配额% [6]: " quota
    quota=${quota:-6}
    if ! [[ "$quota" =~ ^[0-9]+$ ]]; then
        print_status "error" "月度配额必须是数字"
        return 1
    fi

    read -p "K8s预留% [10]: " k8s_reserve
    k8s_reserve=${k8s_reserve:-10}
    if ! [[ "$k8s_reserve" =~ ^[0-9]+$ ]]; then
        print_status "error" "K8s预留必须是数字"
        return 1
    fi

    read -p "内存限制MB [256]: " mem_limit
    mem_limit=${mem_limit:-256}
    if ! [[ "$mem_limit" =~ ^[0-9]+$ ]]; then
        print_status "error" "内存限制必须是数字"
        return 1
    fi

    # 保存配置（已校验，格式安全）
    cat > "${STATE_DIR}/config" << EOF
--target $target
--interval $interval
$max_workers_arg
--quota $quota
--k8s-reserve $k8s_reserve
--mem-limit $mem_limit
EOF

    print_status "ok" "配置已保存到 ${STATE_DIR}/config"
    echo ""
    echo -e "${YELLOW}请重启守护进程使配置生效${NC}"
}

do_show_config() {
    print_header
    echo -e "${BLUE}=== 当前配置 ===${NC}"
    echo ""

    if [ -f "${STATE_DIR}/config" ]; then
        echo -e "${CYAN}已保存的配置:${NC}"
        cat "${STATE_DIR}/config"
    else
        print_status "warn" "无已保存配置"
    fi

    echo ""
    echo -e "${CYAN}默认值:${NC}"
    echo "  目标水位:       40%"
    echo "  监控间隔:       2秒"
    echo "  最大worker:     核心数/2"
    echo "  月度配额:       6%"
    echo "  K8s预留:        10%"
    echo "  内存限制:       256 MB"
    echo "  看门狗:         已启用"
    echo ""
}

do_cleanup() {
    print_header
    echo -e "${BLUE}=== 清理 ===${NC}"
    echo ""

    if check_running; then
        print_status "error" "守护进程正在运行，请先停止"
        return 1
    fi

    # 显示将要执行的命令
    echo -e "${YELLOW}将要执行以下操作:${NC}"
    echo ""
    echo -e "  ${CYAN}将删除以下文件和目录:${NC}"
    echo -e "     命令: rm -rf $STATE_DIR"
    echo -e "           rm -f $LOG_FILE"
    echo -e "           rm -f $WATCHDOG_LOG"
    echo ""
    echo -e "  ${CYAN}删除内容:${NC}"
    echo -e "     - 状态目录: $STATE_DIR"
    echo -e "       (包含PID文件、锁文件、配额文件、worker目录)"
    echo -e "     - 日志文件: $LOG_FILE"
    echo -e "     - 看门狗日志: $WATCHDOG_LOG"
    echo ""
    echo -e "${RED}警告: 此操作不可恢复!${NC}"
    echo -e "${YELLOW}影响: 所有状态和日志将被永久删除，配额信息将丢失${NC}"
    echo ""
    read -p "确认清理? (y/n): " confirm
    if [ "$confirm" != "y" ]; then
        print_status "warn" "已取消清理操作"
        return 0
    fi

    # 二次确认
    read -p "再次确认 (输入 yes): " confirm2
    if [ "$confirm2" != "yes" ]; then
        print_status "warn" "已取消清理操作"
        return 0
    fi

    rm -rf "$STATE_DIR"
    rm -f "$LOG_FILE"
    rm -f "$WATCHDOG_LOG"

    print_status "ok" "清理完成"
}

do_uninstall() {
    print_header
    echo -e "${BLUE}=== 卸载 ===${NC}"
    echo ""

    # 显示将要执行的命令
    echo -e "${YELLOW}将要执行以下操作:${NC}"
    echo ""
    echo -e "  ${CYAN}1. 停止守护进程 (如果运行中)${NC}"
    if check_running; then
        echo -e "     命令: kill -TERM $(get_pid)"
    else
        echo -e "     状态: 未运行，跳过"
    fi
    echo ""
    echo -e "  ${CYAN}2. 从crontab移除看门狗${NC}"
    if crontab -l 2>/dev/null | grep -q "cpu_stress_watchdog"; then
        echo -e "     命令: crontab -l | grep -v cpu_stress_watchdog | crontab -"
    else
        echo -e "     状态: 未配置，跳过"
    fi
    echo ""
    echo -e "  ${CYAN}3. 删除所有状态文件${NC}"
    echo -e "     命令: rm -rf $STATE_DIR"
    echo -e "           rm -f $LOG_FILE"
    echo -e "           rm -f $WATCHDOG_LOG"
    echo ""
    echo -e "  ${CYAN}4. 删除脚本文件${NC}"
    echo -e "     命令: rm -f $STRESS_SCRIPT"
    echo -e "           rm -f $WATCHDOG_SCRIPT"
    echo -e "           rm -f $0"
    echo ""
    echo -e "${RED}警告: 此操作不可恢复!${NC}"
    echo -e "${RED}警告: 控制脚本本身也将被删除!${NC}"
    echo -e "${YELLOW}影响: 所有文件、状态、配置将被永久删除${NC}"
    echo ""
    read -p "确认卸载? (y/n): " confirm
    if [ "$confirm" != "y" ]; then
        print_status "warn" "已取消卸载操作"
        return 0
    fi

    # 二次确认
    read -p "再次确认 (输入 yes): " confirm2
    if [ "$confirm2" != "yes" ]; then
        print_status "warn" "已取消卸载操作"
        return 0
    fi

    # 停止守护进程
    if check_running; then
        do_stop
    fi

    # 移除看门狗
    if crontab -l 2>/dev/null | grep -q "cpu_stress_watchdog"; then
        crontab -l 2>/dev/null | grep -v "cpu_stress_watchdog" | crontab -
        print_status "ok" "看门狗已从crontab移除"
    fi

    # 删除文件
    rm -rf "$STATE_DIR"
    rm -f "$LOG_FILE"
    rm -f "$WATCHDOG_LOG"
    rm -f "$STRESS_SCRIPT"
    rm -f "$WATCHDOG_SCRIPT"
    rm -f "$0"

    print_status "ok" "卸载完成"
}

# ======================== 快捷操作 ========================
do_quick_start() {
    print_header
    echo -e "${BLUE}=== 快速启动 ===${NC}"
    echo ""

    if check_running; then
        print_status "warn" "守护进程已在运行"
        return 0
    fi

    local target=${1:-40}
    print_status "info" "启动目标: ${target}%"

    # 自动检测K8s（使用数组方式，安全）
    local cmd_array=("python3" "$STRESS_SCRIPT" "--target" "$target" "--daemon" "--log-file" "$LOG_FILE")
    if command -v kubectl &>/dev/null && sudo -n kubectl get nodes &>/dev/null 2>&1; then
        cmd_array+=("--protect-k8s" "--check-eviction")
        print_status "info" "K8s保护: 已启用"
    else
        cmd_array+=("--no-protect-k8s" "--no-check-eviction")
        print_status "warn" "K8s保护: 已禁用 (kubectl不可用)"
    fi

    "${cmd_array[@]}"
    sleep 2

    if check_running; then
        print_status "ok" "守护进程已启动 (PID=$(get_pid))"
    else
        print_status "error" "启动失败"
        tail -10 "$LOG_FILE" 2>/dev/null
    fi
}

do_quick_stop() {
    if check_running; then
        local pid=$(get_pid)
        echo -e "${YELLOW}将要执行: kill -TERM $pid${NC}"
        read -p "确认停止? (y/n): " confirm
        if [ "$confirm" != "y" ]; then
            echo -e "${YELLOW}已取消${NC}"
            return 0
        fi
        kill -TERM $pid 2>/dev/null
        sleep 2
        print_status "ok" "守护进程已停止"
    else
        print_status "warn" "守护进程未运行"
    fi
}

do_quick_status() {
    if check_running; then
        echo -e "${GREEN}运行中${NC} (PID=$(get_pid))"
    else
        echo -e "${YELLOW}已停止${NC}"
    fi
}

# ======================== 主菜单 ========================
show_menu() {
    print_header

    # 显示当前状态
    if check_running; then
        echo -e "  ${GREEN}状态: 运行中${NC} (PID=$(get_pid))"
    else
        echo -e "  ${YELLOW}状态: 已停止${NC}"
    fi
    echo ""

    echo -e "${CYAN}  [1]  启动守护进程${NC}"
    echo -e "${CYAN}  [2]  停止守护进程${NC}"
    echo -e "${CYAN}  [3]  重启守护进程${NC}"
    echo -e "${CYAN}  [4]  查看状态${NC}"
    echo ""
    echo -e "${CYAN}  [5]  调整目标水位${NC}"
    echo -e "${CYAN}  [6]  查看日志${NC}"
    echo -e "${CYAN}  [7]  查看配额${NC}"
    echo ""
    echo -e "${CYAN}  [8]  部署看门狗${NC}"
    echo -e "${CYAN}  [9]  移除看门狗${NC}"
    echo ""
    echo -e "${CYAN}  [10] 保存配置${NC}"
    echo -e "${CYAN}  [11] 查看配置${NC}"
    echo ""
    echo -e "${CYAN}  [12] 清理${NC}"
    echo -e "${CYAN}  [13] 卸载${NC}"
    echo ""
    echo -e "${CYAN}  [0]  退出${NC}"
    echo ""
    echo -e "${YELLOW}  快捷命令:${NC}"
    echo -e "  $0 start [目标]"
    echo -e "  $0 stop"
    echo -e "  $0 status"
    echo -e "  $0 log"
    echo ""
}

# ======================== 主函数 ========================
main() {
    # 处理命令行参数
    case "${1:-}" in
        start)
            do_quick_start "${2:-40}"
            exit $?
            ;;
        stop)
            do_quick_stop
            exit $?
            ;;
        status)
            do_quick_status
            exit $?
            ;;
        log)
            do_view_log
            exit $?
            ;;
        help|--help|-h)
            echo "用法: $0 [命令]"
            echo ""
            echo "命令:"
            echo "  start [目标]   启动守护进程 (默认目标: 40%)"
            echo "  stop           停止守护进程"
            echo "  status         查看守护进程状态"
            echo "  log            查看日志"
            echo "  help           显示此帮助"
            echo ""
            echo "不带参数时显示交互式菜单。"
            exit 0
            ;;
    esac

    # 交互式菜单
    while true; do
        show_menu
        read -p "请选择: " choice

        case $choice in
            1)  do_start ;;
            2)  do_stop ;;
            3)  do_restart ;;
            4)  do_status ;;
            5)  do_adjust_target ;;
            6)  do_view_log ;;
            7)  do_view_quota ;;
            8)  do_deploy_watchdog ;;
            9)  do_remove_watchdog ;;
            10) do_save_config ;;
            11) do_show_config ;;
            12) do_cleanup ;;
            13) do_uninstall ;;
            0)  echo -e "${GREEN}再见!${NC}"; exit 0 ;;
            *)  echo -e "${RED}无效选项${NC}" ;;
        esac

        echo ""
        read -p "按回车继续..."
    done
}

main "$@"
