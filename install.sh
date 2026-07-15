#!/usr/bin/env bash
# dipguard - 国内 Debian 监控机上的动态 IP VPS 任务管理器
# 功能：
# - 多 VPS 任务添加、修改、删除、启用、停用
# - 每台任务独立设置检测周期、Ping 次数、失败轮数、每日换 IP 上限等
# - DDNS 未变化时不重复提交（可配置超时重试）；新 IP 连续检测失败后自动继续换 IP
# - Telegram 通知与远程命令控制
#
# 运行：
#   sudo bash digp.sh
#   dipguard --daemon
#   dipguard --check-all

set -Eeuo pipefail
export LC_ALL=C

APP="dipguard"
VERSION="3.8.0"

BASE_DIR="/etc/${APP}"
NODES_DIR="${BASE_DIR}/nodes"
GLOBAL_CONF="${BASE_DIR}/global.conf"
STATE_DIR="/var/lib/${APP}"
LOG_FILE="/var/log/${APP}.log"
BIN_PATH="/usr/local/sbin/${APP}"
SERVICE_FILE="/etc/systemd/system/${APP}.service"
SCRIPT_URL="https://raw.githubusercontent.com/hiapb/dipg/main/install.sh"
INSTALLED_PACKAGES_FILE="${BASE_DIR}/installed-packages"

# 普通文件运行时可直接复制自身；bash <(curl ...) 时该路径通常指向
# /dev/fd 或 /proc/.../pipe，不能当作普通文件安装。
SELF_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || true)"

# ---------------------------------------------------------------------------
# 基础函数
# ---------------------------------------------------------------------------

# 菜单既可能在交互终端中运行，也可能被重定向到日志或脚本中。
# 只有真正的终端才启用颜色，避免把 ANSI 控制字符写进日志。
if [[ -t 1 && -t 2 && -z "${NO_COLOR:-}" ]]; then
    UI_RESET=$'\033[0m'
    UI_BOLD=$'\033[1m'
    UI_DIM=$'\033[2m'
    UI_BLUE=$'\033[38;5;39m'
    UI_CYAN=$'\033[38;5;80m'
    UI_GREEN=$'\033[38;5;114m'
    UI_YELLOW=$'\033[38;5;221m'
    UI_RED=$'\033[38;5;203m'
else
    UI_RESET=""
    UI_BOLD=""
    UI_DIM=""
    UI_BLUE=""
    UI_CYAN=""
    UI_GREEN=""
    UI_YELLOW=""
    UI_RED=""
fi

ui_header() {
    local title="$1" subtitle="${2:-}"
    printf '\n%s%s%s\n' "$UI_BOLD$UI_BLUE" "$title" "$UI_RESET"
    [[ -n "$subtitle" ]] && printf '%s%s%s\n' "$UI_DIM" "$subtitle" "$UI_RESET"
    printf '%s\n' "────────────────────────────────────────────────────────"
}

ui_section() {
    printf '\n%s%s%s\n' "$UI_BOLD$UI_CYAN" "$1" "$UI_RESET"
}

ui_info() {
    printf '%s•%s %s\n' "$UI_CYAN" "$UI_RESET" "$*"
}

ui_ok() {
    printf '%s✓%s %s\n' "$UI_GREEN" "$UI_RESET" "$*"
}

ui_warn() {
    printf '%s!%s %s\n' "$UI_YELLOW" "$UI_RESET" "$*" >&2
}

ui_error() {
    printf '%s✗%s %s\n' "$UI_RED" "$UI_RESET" "$*" >&2
}

pause_menu() {
    local ignored
    printf '\n%s按回车返回主菜单%s' "$UI_DIM" "$UI_RESET" >&2
    IFS= read -r ignored || true
}

trim_input() {
    local value="${1:-}"
    value="$(printf '%s' "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    printf '%s\n' "$value"
}

lower_input() {
    printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'
}

command_available() {
    command -v "$1" >/dev/null 2>&1
}

show_command_block() {
    local command="$1"
    if [[ -z "$(trim_input "$command")" ]]; then
        printf '  （未设置）\n'
    else
        printf '%s\n' "$command" | sed 's/^/  /'
    fi
}

validate_change_command() {
    local command="${1:-}" syntax_error

    [[ -n "$(trim_input "$command")" ]] || {
        ui_error "换 IP 命令为空。"
        return 1
    }

    if ! syntax_error="$(bash -n -c "$command" 2>&1)"; then
        ui_error "换 IP 命令存在 Shell 语法错误："
        printf '%s\n' "$syntax_error" | sed 's/^/  /' >&2
        return 1
    fi

    if ! command_available timeout; then
        ui_error "当前系统缺少 timeout，命令即使正确也无法执行。请先安装 coreutils。"
        return 1
    fi

    if ! command_available flock; then
        ui_error "当前系统缺少 flock，脚本无法安全防止重复换 IP。请先安装 util-linux。"
        return 1
    fi

    return 0
}

show_change_command_info() {
    local command="$1" output_file="${2:-}"

    ui_section "换 IP 命令"
    show_command_block "$command"

    if validate_change_command "$command"; then
        ui_ok "Shell 语法和基础依赖检查通过；这里不会偷偷真实执行命令。"
    else
        return 1
    fi

    if [[ -n "$output_file" && -f "$output_file" ]]; then
        ui_section "上次执行输出"
        if [[ -s "$output_file" ]]; then
            tail -n 30 "$output_file" | sed 's/^/  /'
        else
            printf '  （命令没有输出）\n'
        fi
    fi
}

format_log_line() {
    local line="$1" color="$UI_DIM" marker="·"

    case "$line" in
        *失败*|*错误*|*未成功*|*失败：*)
            color="$UI_RED"
            marker="✗"
            ;;
        *警告*|*达到上限*|*冷却中*|*等待*)
            color="$UI_YELLOW"
            marker="!"
            ;;
        *成功*|*完成*|*恢复*|*已提交*)
            color="$UI_GREEN"
            marker="✓"
            ;;
    esac

    printf '%s%s%s %s%s\n' "$color" "$marker" "$UI_RESET" "$line" "$UI_RESET"
}

require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        echo "请使用 root 运行。"
        exit 1
    fi
}

ensure_dirs() {
    mkdir -p "$NODES_DIR" "$STATE_DIR"
    chmod 700 "$BASE_DIR" "$NODES_DIR" "$STATE_DIR"
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"

    if [[ ! -f "$GLOBAL_CONF" ]]; then
        cat > "$GLOBAL_CONF" <<'EOF'
TG_ENABLED=0
TG_BOT_TOKEN=''
TG_CHAT_ID=''
TG_COMMANDS_ENABLED=1
TG_POLL_INTERVAL=3
TG_PROXY_ENABLED=0
TG_PROXY_URL=''
EOF
        chmod 600 "$GLOBAL_CONF"
    fi
}

log_msg() {
    local node="$1"
    shift
    local line="[$(date '+%F %T')] [$node] $*"
    echo "$line"
    printf '%s\n' "$line" >> "$LOG_FILE"
    logger -t "${APP}[${node}]" -- "$*" 2>/dev/null || true
}

is_uint() {
    [[ "${1:-}" =~ ^[0-9]+$ ]]
}

canonical_uint() {
    is_uint "${1:-}" || return 1
    ((${#1} <= 18)) || return 1
    printf '%d\n' "$((10#$1))"
}

is_int() {
    [[ "${1:-}" =~ ^-?[0-9]+$ ]]
}

is_ipv4() {
    local ip="${1:-}" a b c d
    IFS='.' read -r a b c d <<< "$ip"

    [[ -n "${a:-}" && -n "${b:-}" && -n "${c:-}" && -n "${d:-}" ]] || return 1
    [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ &&
       "$c" =~ ^[0-9]+$ && "$d" =~ ^[0-9]+$ ]] || return 1
    ((${#a} <= 3 && ${#b} <= 3 && ${#c} <= 3 && ${#d} <= 3)) || return 1
    [[ "$a" == "0" || "$a" != 0* ]] &&
        [[ "$b" == "0" || "$b" != 0* ]] &&
        [[ "$c" == "0" || "$c" != 0* ]] &&
        [[ "$d" == "0" || "$d" != 0* ]] || return 1

    ((10#$a <= 255 && 10#$b <= 255 && 10#$c <= 255 && 10#$d <= 255))
}

extract_ipv4() {
    local text="$1" ip found=""

    # 先按“非数字/点”切成完整候选，再严格校验四段，既不会从长数字
    # 中截出假地址，也不会因前一个无效候选而漏掉后面的有效地址。
    while IFS= read -r ip; do
        if is_ipv4 "$ip"; then
            if [[ -z "$found" ]]; then
                found="$ip"
            elif [[ "$found" != "$ip" ]]; then
                return 2
            fi
        fi
    done < <(printf '%s\n' "$text" | tr -cs '0-9.\n' '\n')

    [[ -n "$found" ]] || return 1
    printf '%s\n' "$found"
}

format_duration() {
    local total="${1:-0}" d h m s
    is_uint "$total" || total=0
    d=$((total / 86400))
    h=$(((total % 86400) / 3600))
    m=$(((total % 3600) / 60))
    s=$((total % 60))

    if ((d > 0)); then
        printf '%d天%02d小时%02d分%02d秒' "$d" "$h" "$m" "$s"
    elif ((h > 0)); then
        printf '%d小时%02d分%02d秒' "$h" "$m" "$s"
    elif ((m > 0)); then
        printf '%d分%02d秒' "$m" "$s"
    else
        printf '%d秒' "$s"
    fi
}

valid_node_id() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$ ]]
}

node_exists() {
    [[ -f "${NODES_DIR}/$1/config" ]]
}

node_ids() {
    local d
    shopt -s nullglob
    for d in "$NODES_DIR"/*; do
        [[ -d "$d" && -f "$d/config" ]] && basename "$d"
    done
    shopt -u nullglob
}

read_number_state() {
    local file="$1"
    local default="${2:-0}"
    local value="$default"

    if [[ -f "$file" ]]; then
        value="$(cat "$file" 2>/dev/null || echo "$default")"
    fi

    if ! value="$(canonical_uint "$value")"; then
        value="$default"
    fi
    printf '%s\n' "$value"
}

# ---------------------------------------------------------------------------
# 全局与 Telegram 配置
# ---------------------------------------------------------------------------

load_global() {
    TG_ENABLED=0
    TG_BOT_TOKEN=""
    TG_CHAT_ID=""
    TG_COMMANDS_ENABLED=1
    TG_POLL_INTERVAL=3
    TG_PROXY_ENABLED=0
    TG_PROXY_URL=""

    # 文件由脚本生成，仅 root 可写。
    # shellcheck disable=SC1090
    if ! source "$GLOBAL_CONF"; then
        TG_ENABLED=0
        TG_COMMANDS_ENABLED=0
        TG_PROXY_ENABLED=0
        printf 'Telegram 配置文件格式错误，已临时停用：%s\n' "$GLOBAL_CONF" >&2
    fi

    [[ "${TG_ENABLED:-}" == "0" || "${TG_ENABLED:-}" == "1" ]] || TG_ENABLED=0
    [[ "${TG_COMMANDS_ENABLED:-}" == "0" ||
       "${TG_COMMANDS_ENABLED:-}" == "1" ]] || TG_COMMANDS_ENABLED=1
    [[ "${TG_PROXY_ENABLED:-}" == "0" ||
       "${TG_PROXY_ENABLED:-}" == "1" ]] || TG_PROXY_ENABLED=0

    TG_POLL_INTERVAL="$(canonical_uint "${TG_POLL_INTERVAL:-}" 2>/dev/null || echo 3)"
    is_uint "${TG_POLL_INTERVAL:-}" &&
        ((TG_POLL_INTERVAL >= 2 && TG_POLL_INTERVAL <= 60)) || TG_POLL_INTERVAL=3
}

save_global() {
    {
        printf 'TG_ENABLED=%q\n' "$TG_ENABLED"
        printf 'TG_BOT_TOKEN=%q\n' "$TG_BOT_TOKEN"
        printf 'TG_CHAT_ID=%q\n' "$TG_CHAT_ID"
        printf 'TG_COMMANDS_ENABLED=%q\n' "$TG_COMMANDS_ENABLED"
        printf 'TG_POLL_INTERVAL=%q\n' "$TG_POLL_INTERVAL"
        printf 'TG_PROXY_ENABLED=%q\n' "$TG_PROXY_ENABLED"
        printf 'TG_PROXY_URL=%q\n' "$TG_PROXY_URL"
    } > "$GLOBAL_CONF"
    chmod 600 "$GLOBAL_CONF"
}

tg_curl() {
    load_global

    if [[ "$TG_PROXY_ENABLED" == "1" && -n "$TG_PROXY_URL" ]]; then
        curl --proxy "$TG_PROXY_URL" "$@"
    else
        curl "$@"
    fi
}

tg_proxy_description() {
    load_global

    if [[ "$TG_PROXY_ENABLED" == "1" && -n "$TG_PROXY_URL" ]]; then
        local safe="$TG_PROXY_URL"
        # 隐藏代理 URL 中可能存在的密码。
        safe="$(printf '%s' "$safe" | sed -E 's#(://[^:/@]+:)[^@]+@#\1******@#')"
        printf '%s\n' "$safe"
    else
        printf '%s\n' "直连"
    fi
}

tg_ready() {
    load_global
    [[ "$TG_ENABLED" == "1" && -n "$TG_BOT_TOKEN" && -n "$TG_CHAT_ID" ]]
}

tg_send_to() {
    local chat_id="$1"
    local text="$2"
    local reply_markup="${3:-}"

    load_global
    [[ -n "$TG_BOT_TOKEN" && -n "$chat_id" ]] || return 1

    local args=(
        -fsS
        --max-time 15
        -X POST
        "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage"
        --data-urlencode "chat_id=${chat_id}"
        --data-urlencode "text=${text}"
        --data-urlencode "disable_web_page_preview=true"
    )

    if [[ -n "$reply_markup" ]]; then
        args+=(--data-urlencode "reply_markup=${reply_markup}")
    fi

    tg_curl "${args[@]}" >/dev/null
}

tg_edit_message() {
    local chat_id="$1"
    local message_id="$2"
    local text="$3"
    local reply_markup="${4:-}"

    load_global
    [[ -n "$TG_BOT_TOKEN" && -n "$chat_id" && -n "$message_id" ]] || return 1

    local args=(
        -fsS
        --max-time 15
        -X POST
        "https://api.telegram.org/bot${TG_BOT_TOKEN}/editMessageText"
        --data-urlencode "chat_id=${chat_id}"
        --data-urlencode "message_id=${message_id}"
        --data-urlencode "text=${text}"
        --data-urlencode "disable_web_page_preview=true"
    )

    if [[ -n "$reply_markup" ]]; then
        args+=(--data-urlencode "reply_markup=${reply_markup}")
    fi

    # “message is not modified” 不属于实际故障。
    tg_curl "${args[@]}" >/dev/null 2>&1 || true
}

tg_answer_callback() {
    local callback_id="$1"
    local text="${2:-}"
    local show_alert="${3:-false}"

    load_global
    [[ -n "$TG_BOT_TOKEN" && -n "$callback_id" ]] || return 1

    local args=(
        -fsS
        --max-time 10
        -X POST
        "https://api.telegram.org/bot${TG_BOT_TOKEN}/answerCallbackQuery"
        --data-urlencode "callback_query_id=${callback_id}"
        --data-urlencode "show_alert=${show_alert}"
    )

    if [[ -n "$text" ]]; then
        args+=(--data-urlencode "text=${text}")
    fi

    tg_curl "${args[@]}" >/dev/null 2>&1 || true
}

tg_notify() {
    local text="$1"
    tg_ready || return 0

    tg_send_to "$TG_CHAT_ID" "$text" "$(tg_main_keyboard)" || {
        log_msg "TELEGRAM" "发送通知失败"
        return 1
    }
}

tg_get_latest_chat_id() {
    local result
    load_global
    [[ -n "$TG_BOT_TOKEN" ]] || return 1

    result="$(
        tg_curl -fsS --max-time 15 \
            "https://api.telegram.org/bot${TG_BOT_TOKEN}/getUpdates?limit=100" 2>/dev/null
    )" || return 1

    printf '%s\n' "$result" |
        jq -r '
            [.result[] |
             (.message.chat.id // .edited_message.chat.id // .callback_query.message.chat.id // empty)]
            | last // empty
        '
}

tg_test() {
    if ! tg_ready; then
        echo "Telegram 未启用，或 Bot Token / Chat ID 未配置完整。"
        return 1
    fi

    if tg_notify "✅ Dynamic IP Guard Telegram 测试成功
时间：$(date '+%F %T')
主机：$(hostname)
连接方式：$(tg_proxy_description)"; then
        echo "测试消息已发送。"
    else
        echo "发送失败，请检查 Token、Chat ID 和网络。"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# 节点配置
# ---------------------------------------------------------------------------

normalize_node_config() {
    local fallback_name="$NODE_ID" key value

    # Bash 会把 08、09 当作非法八进制；配置与交互输入先统一成十进制。
    for key in \
        MAX_DAILY CHECK_INTERVAL CHECK_PORT PING_COUNT PING_MIN_REPLIES \
        PING_TIMEOUT FAIL_ROUNDS GET_IP_TIMEOUT CHANGE_CMD_TIMEOUT \
        COOLDOWN_SECONDS DDNS_WAIT_TIMEOUT; do
        value="${!key:-}"
        if value="$(canonical_uint "$value" 2>/dev/null)"; then
            printf -v "$key" '%s' "$value"
        else
            printf -v "$key" '%s' ""
        fi
    done

    NAME="$(trim_input "${NAME:-}")"
    [[ -n "$NAME" ]] || NAME="$fallback_name"

    [[ "$ENABLED" == "0" || "$ENABLED" == "1" ]] || ENABLED=1
    is_uint "$MAX_DAILY" || MAX_DAILY=5

    is_uint "$CHECK_INTERVAL" &&
        ((CHECK_INTERVAL >= 10 && CHECK_INTERVAL <= 86400)) || CHECK_INTERVAL=10

    CHECK_MODE="$(lower_input "$CHECK_MODE")"
    case "$CHECK_MODE" in
        ping|tcp|either|both) ;;
        *) CHECK_MODE="ping" ;;
    esac

    is_uint "$CHECK_PORT" &&
        ((CHECK_PORT >= 1 && CHECK_PORT <= 65535)) || CHECK_PORT=443
    is_uint "$PING_COUNT" &&
        ((PING_COUNT >= 1 && PING_COUNT <= 20)) || PING_COUNT=3
    is_uint "$PING_MIN_REPLIES" &&
        ((PING_MIN_REPLIES >= 1 && PING_MIN_REPLIES <= PING_COUNT)) ||
        PING_MIN_REPLIES=1
    is_uint "$PING_TIMEOUT" &&
        ((PING_TIMEOUT >= 1 && PING_TIMEOUT <= 20)) || PING_TIMEOUT=3
    is_uint "$FAIL_ROUNDS" &&
        ((FAIL_ROUNDS >= 1 && FAIL_ROUNDS <= 100)) || FAIL_ROUNDS=3

    is_uint "$GET_IP_TIMEOUT" &&
        ((GET_IP_TIMEOUT >= 1 && GET_IP_TIMEOUT <= 300)) || GET_IP_TIMEOUT=30
    is_uint "$CHANGE_CMD_TIMEOUT" &&
        ((CHANGE_CMD_TIMEOUT >= 1 && CHANGE_CMD_TIMEOUT <= 600)) ||
        CHANGE_CMD_TIMEOUT=90
    is_uint "$COOLDOWN_SECONDS" &&
        ((COOLDOWN_SECONDS <= 86400)) || COOLDOWN_SECONDS=600
    is_uint "$DDNS_WAIT_TIMEOUT" &&
        ((DDNS_WAIT_TIMEOUT <= 86400)) || DDNS_WAIT_TIMEOUT=300
}

load_node() {
    local id="$1"
    node_exists "$id" || return 1

    NODE_ID="$id"
    NODE_DIR="${NODES_DIR}/${id}"
    NODE_STATE="${STATE_DIR}/${id}"

    NAME="$id"
    ENABLED=1
    MAX_DAILY=5

    CHECK_INTERVAL=10
    CHECK_MODE="ping"
    CHECK_PORT=443

    PING_COUNT=3
    PING_MIN_REPLIES=1
    PING_TIMEOUT=3
    FAIL_ROUNDS=3

    GET_IP_TIMEOUT=30
    CHANGE_CMD_TIMEOUT=90
    COOLDOWN_SECONDS=600
    DDNS_WAIT_TIMEOUT=300

    # 文件由脚本生成，仅 root 可写。
    # shellcheck disable=SC1090
    if ! source "${NODE_DIR}/config"; then
        log_msg "SYSTEM" "任务配置格式错误，已跳过：${NODE_ID}"
        return 1
    fi

    # 旧版本配置或手工修改的异常值不能进入算术判断，否则可能导致整个
    # 后台循环退出。这里统一回落到安全值，并保证最低回复数不超过次数。
    normalize_node_config

    # v3.5 起，换 IP 后复用正常检测周期，不再单独设置查询间隔。
    # 旧配置中的 IP_POLL_INTERVAL 会被忽略。
    unset IP_POLL_INTERVAL 2>/dev/null || true

    mkdir -p "$NODE_STATE"
    chmod 700 "$NODE_STATE"
}

save_node_config() {
    local file="$1"
    {
        printf 'NAME=%q\n' "$NAME"
        printf 'ENABLED=%q\n' "$ENABLED"
        printf 'MAX_DAILY=%q\n' "$MAX_DAILY"
        printf 'CHECK_INTERVAL=%q\n' "$CHECK_INTERVAL"
        printf 'CHECK_MODE=%q\n' "$CHECK_MODE"
        printf 'CHECK_PORT=%q\n' "$CHECK_PORT"
        printf 'PING_COUNT=%q\n' "$PING_COUNT"
        printf 'PING_MIN_REPLIES=%q\n' "$PING_MIN_REPLIES"
        printf 'PING_TIMEOUT=%q\n' "$PING_TIMEOUT"
        printf 'FAIL_ROUNDS=%q\n' "$FAIL_ROUNDS"
        printf 'GET_IP_TIMEOUT=%q\n' "$GET_IP_TIMEOUT"
        printf 'CHANGE_CMD_TIMEOUT=%q\n' "$CHANGE_CMD_TIMEOUT"
        printf 'COOLDOWN_SECONDS=%q\n' "$COOLDOWN_SECONDS"
        printf 'DDNS_WAIT_TIMEOUT=%q\n' "$DDNS_WAIT_TIMEOUT"
    } > "$file"
    chmod 600 "$file"
}

set_enabled() {
    local id="$1" value="$2"
    load_node "$id" || return 1
    ENABLED="$value"
    save_node_config "${NODE_DIR}/config"

    if [[ "$value" == "1" ]]; then
        rm -f \
            "${NODE_STATE}/last_check" \
            "${NODE_STATE}/last_check_result" \
            "${NODE_STATE}/last_check_detail"
        log_msg "$NAME" "任务已启用"
    else
        log_msg "$NAME" "任务已停用"
    fi
}

run_saved_command() {
    local command_file="$1" timeout_seconds="$2"
    local command

    [[ -r "$command_file" ]] || {
        printf '命令文件不存在或不可读：%s\n' "$command_file" >&2
        return 127
    }
    command_available timeout || {
        printf '缺少 timeout 命令，请先安装 coreutils。\n' >&2
        return 127
    }

    command="$(cat "$command_file")"
    [[ -n "$(trim_input "$command")" ]] || {
        printf '命令文件为空：%s\n' "$command_file" >&2
        return 127
    }
    timeout --signal=TERM --kill-after=5 "${timeout_seconds}s" bash -lc "$command"
}

get_current_ip() {
    local output rc ip extract_rc

    set +e
    output="$(run_saved_command "${NODE_DIR}/get_ip.cmd" "$GET_IP_TIMEOUT" 2>&1)"
    rc=$?
    set -e

    if ((rc != 0)); then
        printf '%s\n' "$output" > "${NODE_STATE}/last_get_ip_error"
        chmod 600 "${NODE_STATE}/last_get_ip_error"
        return 1
    fi

    set +e
    ip="$(extract_ipv4 "$output")"
    extract_rc=$?
    set -e

    if ((extract_rc == 0)); then
        rm -f "${NODE_STATE}/last_get_ip_error"
        printf '%s\n' "$ip"
        return 0
    fi

    if ((extract_rc == 2)); then
        printf '%s\n\n%s\n' \
            "检测到多个不同的 IPv4，无法确定哪一个属于目标 VPS：" \
            "$output" > "${NODE_STATE}/last_get_ip_error"
    else
        printf '%s\n' "$output" > "${NODE_STATE}/last_get_ip_error"
    fi
    chmod 600 "${NODE_STATE}/last_get_ip_error"
    return 1
}

# ---------------------------------------------------------------------------
# 检测
# ---------------------------------------------------------------------------

ping_reply_count() {
    local ip="$1" output received

    if ! command_available ping; then
        printf '0\n'
        return 127
    fi

    set +e
    output="$(ping -n -c "$PING_COUNT" -W "$PING_TIMEOUT" "$ip" 2>&1)"
    set -e

    received="$(
        printf '%s\n' "$output" |
        awk -F', ' '/packets transmitted/ {
            for (i=1; i<=NF; i++) {
                if ($i ~ /received/) {
                    gsub(/[^0-9]/, "", $i)
                    print $i
                    exit
                }
            }
        }'
    )"

    is_uint "${received:-}" || received=0
    printf '%s\n' "$received"
}

tcp_ok() {
    local ip="$1"

    command_available timeout && command_available nc || return 127
    timeout "$((PING_TIMEOUT + 1))" \
        nc -z -w "$PING_TIMEOUT" "$ip" "$CHECK_PORT" >/dev/null 2>&1
}

probe_reachability() {
    local ip="$1"
    local ping_pass=0 tcp_pass=0

    LAST_PING_REPLIES="-"
    LAST_TCP_RESULT="-"
    LAST_PROBE_ERROR=""

    if [[ "$CHECK_MODE" != "tcp" ]]; then
        if ! command_available ping; then
            LAST_PROBE_ERROR="缺少 ping 命令"
        else
            LAST_PING_REPLIES="$(ping_reply_count "$ip" || true)"
            is_uint "$LAST_PING_REPLIES" || LAST_PING_REPLIES=0
            ((LAST_PING_REPLIES >= PING_MIN_REPLIES)) && ping_pass=1
        fi
    fi

    if [[ "$CHECK_MODE" != "ping" ]]; then
        if ! command_available nc || ! command_available timeout; then
            [[ -n "$LAST_PROBE_ERROR" ]] && LAST_PROBE_ERROR+="；"
            LAST_PROBE_ERROR+="缺少 nc 或 timeout 命令"
        elif tcp_ok "$ip"; then
            tcp_pass=1
            LAST_TCP_RESULT="通"
        else
            LAST_TCP_RESULT="不通"
        fi
    fi

    case "$CHECK_MODE" in
        ping)
            ((ping_pass == 1))
            ;;
        tcp)
            ((tcp_pass == 1))
            ;;
        either)
            ((ping_pass == 1 || tcp_pass == 1))
            ;;
        both)
            ((ping_pass == 1 && tcp_pass == 1))
            ;;
        *)
            return 2
            ;;
    esac
}

check_reachable() {
    probe_reachability "$1"
}

last_probe_summary() {
    local ping_text tcp_text

    ping_text="Ping ${LAST_PING_REPLIES}/${PING_COUNT}（要求 ${PING_MIN_REPLIES}）"
    tcp_text="TCP ${CHECK_PORT} ${LAST_TCP_RESULT}"

    case "$CHECK_MODE" in
        ping) printf '%s\n' "$ping_text" ;;
        tcp) printf '%s\n' "$tcp_text" ;;
        either|both) printf '%s；%s\n' "$ping_text" "$tcp_text" ;;
        *) printf '%s\n' "未知检测模式" ;;
    esac
}

# ---------------------------------------------------------------------------
# 每日次数与 pending 状态
# ---------------------------------------------------------------------------

get_daily_count() {
    local today saved_date count

    today="$(date +%F)"
    saved_date=""
    count=0

    if [[ -f "${NODE_STATE}/daily_usage" ]]; then
        read -r saved_date count < "${NODE_STATE}/daily_usage" || true
    fi

    if [[ "$saved_date" != "$today" ]] || ! is_uint "${count:-}"; then
        count=0
        printf '%s %s\n' "$today" "$count" > "${NODE_STATE}/daily_usage"
        rm -f "${NODE_STATE}/limit_notified_date"
    else
        count="$(canonical_uint "$count" 2>/dev/null || echo 0)"
    fi

    printf '%s\n' "$count"
}

set_daily_count() {
    printf '%s %s\n' "$(date +%F)" "$1" > "${NODE_STATE}/daily_usage"
}

pending_exists() {
    [[ -f "${NODE_STATE}/pending" ]]
}

write_pending() {
    local old_ip="$1" started="$2" reason="$3"

    {
        printf 'OLD_IP=%q\n' "$old_ip"
        printf 'STARTED_AT=%q\n' "$started"
        printf 'CHANGE_REASON=%q\n' "$reason"
    } > "${NODE_STATE}/pending"
    chmod 600 "${NODE_STATE}/pending"
}

read_pending() {
    OLD_IP=""
    STARTED_AT=0
    CHANGE_REASON=""

    [[ -f "${NODE_STATE}/pending" ]] || return 1

    # 文件由脚本生成，仅 root 可写。
    # shellcheck disable=SC1090
    source "${NODE_STATE}/pending" || return 1

    is_ipv4 "$OLD_IP" && is_uint "$STARTED_AT" || return 1
    STARTED_AT="$(canonical_uint "$STARTED_AT" 2>/dev/null)" || return 1
}

clear_pending_validation() {
    rm -f \
        "${NODE_STATE}/pending_candidate_ip" \
        "${NODE_STATE}/pending_candidate_failures" \
        "${NODE_STATE}/pending_limit_wait_date"
}

clear_pending() {
    rm -f "${NODE_STATE}/pending" "${NODE_STATE}/last_pending_poll"
    clear_pending_validation
}

write_check_result() {
    local status="$1" detail="${2:-}"
    printf '%s\n' "$status" > "${NODE_STATE}/last_check_result"
    printf '%s\n' "$detail" > "${NODE_STATE}/last_check_detail"
}

node_health_state() {
    local status last_check age stale_after

    if [[ "$ENABLED" != "1" ]]; then
        printf '已停用\n'
        return
    fi

    if pending_exists && read_pending; then
        printf '等待新 IP（%s）\n' \
            "$(format_duration "$(($(date +%s) - STARTED_AT))")"
        return
    fi

    status="$(cat "${NODE_STATE}/last_check_result" 2>/dev/null || true)"
    last_check="$(read_number_state "${NODE_STATE}/last_check" 0)"

    if ((last_check == 0)) || [[ -z "$status" ]]; then
        printf '尚未检测\n'
        return
    fi

    age=$(($(date +%s) - last_check))
    ((age < 0)) && age=0
    stale_after=$((CHECK_INTERVAL * 3 + 10))

    case "$status" in
        ok)
            if ((age > stale_after)); then
                printf '检测已过期（%s前）\n' "$(format_duration "$age")"
            else
                printf '最近检测正常\n'
            fi
            ;;
        fail) printf '检测失败\n' ;;
        ip_error) printf 'IP 查询失败\n' ;;
        *) printf '状态未知\n' ;;
    esac
}

notify_daily_limit_once() {
    local today
    today="$(date +%F)"

    if [[ "$(cat "${NODE_STATE}/limit_notified_date" 2>/dev/null || true)" == "$today" ]]; then
        return 0
    fi

    printf '%s\n' "$today" > "${NODE_STATE}/limit_notified_date"

    tg_notify "⚠️ 动态 IP 任务达到每日上限
任务：${NAME} (${NODE_ID})
今日次数：$(get_daily_count)/${MAX_DAILY}
最近 IP：$(cat "${NODE_STATE}/last_seen_ip" 2>/dev/null || echo 未知)
自动换 IP 已暂停到次日计数重置。"
}

# ---------------------------------------------------------------------------
# 换 IP
# ---------------------------------------------------------------------------

trigger_change() (
    local change_lock_fd

    if ! command_available flock; then
        log_msg "$NAME" "缺少 flock，未执行换 IP；请先安装 util-linux"
        return 6
    fi

    exec {change_lock_fd}> "${NODE_STATE}/change.lock"
    if ! flock -n "$change_lock_fd"; then
        log_msg "$NAME" "另一个换 IP 请求正在处理，本次未重复提交"
        return 5
    fi

    trigger_change_impl "$@"
)

trigger_change_impl() {
    local current_ip="$1"
    local reason="$2"
    local mode="${3:-auto}"
    local allow_pending_retry="${4:-0}"
    local ignore_cooldown="${5:-0}"
    local count now last_trigger elapsed output rc count_text wait_text request_kind

    [[ "$mode" == "manual" ]] && request_kind="手动" || request_kind="自动"

    if pending_exists && [[ "$allow_pending_retry" != "1" ]]; then
        log_msg "$NAME" "已有换 IP 请求正在等待生效，本次不重复提交"
        return 2
    fi

    count="$(get_daily_count)"

    if ((MAX_DAILY > 0 && count >= MAX_DAILY)); then
        log_msg "$NAME" "今日换 IP 次数已达上限：${count}/${MAX_DAILY}"
        notify_daily_limit_once
        return 3
    fi

    now="$(date +%s)"
    last_trigger="$(read_number_state "${NODE_STATE}/last_trigger" 0)"
    elapsed=$((now - last_trigger))

    if [[ "$ignore_cooldown" != "1" ]] &&
       ((last_trigger > 0 && elapsed < COOLDOWN_SECONDS)); then
        log_msg "$NAME" "换 IP 冷却中：$(format_duration "$elapsed") / $(format_duration "$COOLDOWN_SECONDS")"
        return 4
    fi

    printf '%s\n' "$current_ip" > "${NODE_STATE}/last_seen_ip"
    log_msg "$NAME" "提交${request_kind}换 IP；旧 IP：$current_ip；原因：$reason"

    set +e
    output="$(run_saved_command "${NODE_DIR}/change_ip.cmd" "$CHANGE_CMD_TIMEOUT" 2>&1)"
    rc=$?
    set -e

    printf '%s\n' "$output" > "${NODE_STATE}/last_change_output"
    chmod 600 "${NODE_STATE}/last_change_output"

    if ((rc != 0)); then
        log_msg "$NAME" "换 IP 命令失败，退出码：$rc；本次不计数"

        tg_notify "❌ 换 IP 命令执行失败
任务：${NAME} (${NODE_ID})
旧 IP：${current_ip}
原因：${reason}
退出码：${rc}
本次未计入每日次数。"
        return 1
    fi

    if [[ -n "$(trim_input "$output")" ]]; then
        log_msg "$NAME" "换 IP 命令返回 0；命令输出已保存到任务状态"
    else
        log_msg "$NAME" "换 IP 命令返回 0；命令没有输出"
    fi

    count=$((count + 1))
    set_daily_count "$count"
    printf '%s\n' "$now" > "${NODE_STATE}/last_trigger"
    printf '%s\n' "$now" > "${NODE_STATE}/last_pending_poll"

    # 手动或自动重试时覆盖旧 pending，从本次提交重新计时。
    write_pending "$current_ip" "$now" "$reason"
    clear_pending_validation
    printf '0\n' > "${NODE_STATE}/fail_rounds"

    if ((DDNS_WAIT_TIMEOUT == 0)); then
        wait_text="持续等待 IP 变化"
    else
        wait_text="等待 IP 变化，${DDNS_WAIT_TIMEOUT} 秒未变化则重试"
    fi

    if ((MAX_DAILY == 0)); then
        log_msg "$NAME" "请求已提交，今日第 ${count} 次（不限次数）；${wait_text}"
        count_text="${count}（不限次数）"
    else
        log_msg "$NAME" "请求已提交，今日 ${count}/${MAX_DAILY}；${wait_text}"
        count_text="${count}/${MAX_DAILY}"
    fi

    tg_notify "🔄 已提交换 IP
任务：${NAME} (${NODE_ID})
旧 IP：${current_ip}
原因：${reason}
来源：${request_kind}
今日次数：${count_text}
状态：${wait_text}；新 IP 连续不通时自动继续换。"

    return 0
}

poll_pending() {
    local current_ip now last_poll elapsed
    local candidate_ip candidate_failures rc today blocked_date probe_text

    read_pending || {
        clear_pending
        return 1
    }

    now="$(date +%s)"
    last_poll="$(read_number_state "${NODE_STATE}/last_pending_poll" 0)"

    if ((now - last_poll < CHECK_INTERVAL)); then
        return 0
    fi

    printf '%s\n' "$now" > "${NODE_STATE}/last_pending_poll"

    if ! current_ip="$(get_current_ip)"; then
        log_msg "$NAME" "等待换 IP 生效时查询当前 IP 失败；保持等待，不重复提交"
        return 1
    fi

    printf '%s\n' "$current_ip" > "${NODE_STATE}/last_seen_ip"

    if [[ "$current_ip" == "$OLD_IP" ]]; then
        clear_pending_validation
        elapsed=$((now - STARTED_AT))

        today="$(date +%F)"
        blocked_date="$(cat "${NODE_STATE}/pending_limit_wait_date" 2>/dev/null || true)"

        if (( DDNS_WAIT_TIMEOUT > 0 && elapsed >= DDNS_WAIT_TIMEOUT )) && [[ "$blocked_date" != "$today" ]]; then
            log_msg "$NAME" "DDNS 仍为旧 IP：$current_ip；已等待 $(format_duration "$elapsed")，超过超时时间 ${DDNS_WAIT_TIMEOUT} 秒，自动重试换 IP"

            set +e
            trigger_change "$current_ip" "DDNS 变化超时 (${DDNS_WAIT_TIMEOUT}秒)" "auto" "1" "1"
            rc=$?
            set -e

            case "$rc" in
                0)
                    log_msg "$NAME" "因 DDNS 未变超时，已自动重新提交换 IP"
                    ;;
                3)
                    printf '%s\n' "$today" > "${NODE_STATE}/pending_limit_wait_date"
                    log_msg "$NAME" "DDNS 超时未变，但今日换 IP 次数已达上限；次日自动继续"
                    ;;
                *)
                    log_msg "$NAME" "自动重新提交换 IP 未成功；等待下个周期重试"
                    ;;
            esac
        else
            log_msg "$NAME" "DDNS 仍为旧 IP：$current_ip；已等待 $(format_duration "$elapsed")"
        fi

        return 0
    fi

    # DDNS 已变化，使用任务原有的 Ping/TCP 规则验证新 IP。
    if check_reachable "$current_ip"; then
        probe_text="$(last_probe_summary)"
        [[ -n "$LAST_PROBE_ERROR" ]] && probe_text+="；${LAST_PROBE_ERROR}"
        printf '%s\n' "$now" > "${NODE_STATE}/last_check"
        write_check_result "ok" "$probe_text"

        elapsed=$((now - STARTED_AT))
        clear_pending
        printf '0\n' > "${NODE_STATE}/fail_rounds"
        printf '%s\n' "$now" > "${NODE_STATE}/last_change_completed"

        log_msg "$NAME" "换 IP 完成且检测可用：$OLD_IP -> $current_ip；耗时 $(format_duration "$elapsed")"

        tg_notify "✅ 换 IP 已生效并通过检测
任务：${NAME} (${NODE_ID})
旧 IP：${OLD_IP}
新 IP：${current_ip}
验证方式：${CHECK_MODE}
生效耗时：$(format_duration "$elapsed")
原因：${CHANGE_REASON:-未知}"

        return 0
    fi

    probe_text="$(last_probe_summary)"
    [[ -n "$LAST_PROBE_ERROR" ]] && probe_text+="；${LAST_PROBE_ERROR}"
    printf '%s\n' "$now" > "${NODE_STATE}/last_check"
    write_check_result "fail" "$probe_text"

    # 新 IP 不可用：对同一个候选 IP 统计连续失败轮数。
    candidate_ip="$(cat "${NODE_STATE}/pending_candidate_ip" 2>/dev/null || true)"
    candidate_failures="$(
        read_number_state "${NODE_STATE}/pending_candidate_failures" 0
    )"

    if [[ "$candidate_ip" != "$current_ip" ]]; then
        candidate_ip="$current_ip"
        candidate_failures=1
        printf '%s\n' "$candidate_ip" > "${NODE_STATE}/pending_candidate_ip"
    else
        candidate_failures=$((candidate_failures + 1))
    fi

    printf '%s\n' "$candidate_failures" > \
        "${NODE_STATE}/pending_candidate_failures"

    log_msg "$NAME" \
        "新 IP 检测失败：$current_ip；连续 ${candidate_failures}/${FAIL_ROUNDS} 轮；${probe_text}"

    if ((candidate_failures < FAIL_ROUNDS)); then
        return 0
    fi

    # 如果今日次数已达上限，只等待日期变化，不每 10 秒重复调用换 IP。
    today="$(date +%F)"
    blocked_date="$(
        cat "${NODE_STATE}/pending_limit_wait_date" 2>/dev/null || true
    )"

    if [[ "$blocked_date" == "$today" ]]; then
        return 0
    fi

    log_msg "$NAME" \
        "新 IP $current_ip 连续 ${candidate_failures} 轮不可用，自动继续更换 IP"

    set +e
    trigger_change \
        "$current_ip" \
        "更换后的新 IP 连续 ${candidate_failures} 轮不可用" \
        "auto" \
        "1" \
        "1"
    rc=$?
    set -e

    case "$rc" in
        0)
            log_msg "$NAME" "已自动提交下一次换 IP，坏 IP：$current_ip"
            ;;
        3)
            printf '%s\n' "$today" > \
                "${NODE_STATE}/pending_limit_wait_date"
            log_msg "$NAME" \
                "新 IP 仍不可用，但今日换 IP 次数已达上限；次日自动继续"
            ;;
        *)
            # 命令执行失败时重新累计，避免每个检测周期连续轰炸接口。
            printf '0\n' > "${NODE_STATE}/pending_candidate_failures"
            log_msg "$NAME" \
                "自动继续换 IP 未成功；重新累计 ${FAIL_ROUNDS} 轮后再试"
            ;;
    esac

    return 0
}

# ---------------------------------------------------------------------------
# 节点检查
# ---------------------------------------------------------------------------

check_node() {
    local id="$1"
    local force_due="${2:-0}"
    local current_ip now last_check fail_rounds probe_text lock_fd rc

    load_node "$id" || return 1

    if [[ "$ENABLED" != "1" ]]; then
        return 0
    fi

    exec {lock_fd}> "${NODE_STATE}/lock"
    if ! flock -n "$lock_fd"; then
        exec {lock_fd}>&-
        return 0
    fi

    if pending_exists; then
        poll_pending || true
        flock -u "$lock_fd"
        exec {lock_fd}>&-
        return 0
    fi

    now="$(date +%s)"
    last_check="$(read_number_state "${NODE_STATE}/last_check" 0)"

    if [[ "$force_due" != "1" ]] &&
       ((now - last_check < CHECK_INTERVAL)); then
        flock -u "$lock_fd"
        exec {lock_fd}>&-
        return 0
    fi

    printf '%s\n' "$now" > "${NODE_STATE}/last_check"

    if ! current_ip="$(get_current_ip)"; then
        write_check_result "ip_error" "查询命令未返回有效 IPv4"
        log_msg "$NAME" "查询命令未返回有效 IPv4；为避免误换，本轮跳过"

        flock -u "$lock_fd"
        exec {lock_fd}>&-
        return 1
    fi

    printf '%s\n' "$current_ip" > "${NODE_STATE}/last_seen_ip"

    fail_rounds="$(read_number_state "${NODE_STATE}/fail_rounds" 0)"

    if check_reachable "$current_ip"; then
        probe_text="$(last_probe_summary)"
        [[ -n "$LAST_PROBE_ERROR" ]] && probe_text+="；${LAST_PROBE_ERROR}"
        write_check_result "ok" "$probe_text"

        if ((fail_rounds > 0)); then
            log_msg "$NAME" "检测恢复：$current_ip；连续失败 ${fail_rounds} -> 0"
        fi
        printf '0\n' > "${NODE_STATE}/fail_rounds"
    else
        probe_text="$(last_probe_summary)"
        [[ -n "$LAST_PROBE_ERROR" ]] && probe_text+="；${LAST_PROBE_ERROR}"
        write_check_result "fail" "$probe_text"

        fail_rounds=$((fail_rounds + 1))
        printf '%s\n' "$fail_rounds" > "${NODE_STATE}/fail_rounds"

        log_msg "$NAME" "检测失败：$current_ip；连续失败 ${fail_rounds}/${FAIL_ROUNDS}；${probe_text}"

        if ((fail_rounds >= FAIL_ROUNDS)); then
            set +e
            trigger_change \
                "$current_ip" \
                "连续 ${fail_rounds} 轮检测失败" \
                "auto" \
                "0" \
                "0"
            rc=$?
            set -e

            # 冷却中或达到上限时，不让失败轮数无限增长。
            if ((rc == 3 || rc == 4)); then
                printf '%s\n' "$FAIL_ROUNDS" > "${NODE_STATE}/fail_rounds"
            fi
        fi
    fi

    flock -u "$lock_fd"
    exec {lock_fd}>&-
}

check_all_once() {
    local id found=0 rc=0

    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        found=1
        check_node "$id" 1 || rc=1
    done < <(node_ids)

    ((found == 1)) || log_msg "SYSTEM" "尚未添加任何任务"
    return "$rc"
}

# ---------------------------------------------------------------------------
# Telegram 按钮控制面板
# ---------------------------------------------------------------------------

tg_main_keyboard() {
    jq -cn '{
        inline_keyboard: [
            [
                {text:"📋 任务列表", callback_data:"l"},
                {text:"🔍 检查全部", callback_data:"a"}
            ],
            [
                {text:"🔄 刷新面板", callback_data:"m"}
            ]
        ]
    }'
}

tg_back_main_keyboard() {
    jq -cn '{
        inline_keyboard: [
            [{text:"🏠 返回主面板", callback_data:"m"}]
        ]
    }'
}

tg_main_text() {
    local id total=0 enabled=0 disabled=0 pending=0

    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        total=$((total + 1))
        load_node "$id" || continue

        if [[ "$ENABLED" == "1" ]]; then
            enabled=$((enabled + 1))
        else
            disabled=$((disabled + 1))
        fi

        pending_exists && pending=$((pending + 1))
    done < <(node_ids)

    cat <<EOF
🛡 Dynamic IP Guard

主机：$(hostname)
Telegram 连接：$(tg_proxy_description)
任务总数：${total}
启用：${enabled}
停用：${disabled}
等待新 IP：${pending}

更新时间：$(date '+%F %T')
请直接点击下面按钮。
EOF
}

tg_tasks_keyboard() {
    local id rows='[]' label icon

    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        load_node "$id" || continue

        if pending_exists; then
            icon="⏳"
        elif [[ "$ENABLED" == "1" ]]; then
            icon="🟢"
        else
            icon="⚪"
        fi

        label="${icon} ${NAME} (${id})"
        rows="$(
            jq -c \
                --arg text "$label" \
                --arg data "n:${id}" \
                '. + [[{text:$text,callback_data:$data}]]' \
                <<< "$rows"
        )"
    done < <(node_ids)

    jq -cn \
        --argjson rows "$rows" \
        '$rows + [
            [
                {text:"🔄 刷新",callback_data:"l"},
                {text:"🏠 主面板",callback_data:"m"}
            ]
        ] | {inline_keyboard:.}'
}

node_status_line() {
    local id="$1" ip count fails state enabled daily_text

    load_node "$id" || return 1
    ip="$(cat "${NODE_STATE}/last_seen_ip" 2>/dev/null || echo "-")"
    count="$(get_daily_count)"
    fails="$(read_number_state "${NODE_STATE}/fail_rounds" 0)"

    if [[ "$ENABLED" == "1" ]]; then
        enabled="启用"
    else
        enabled="停用"
    fi

    if ((MAX_DAILY == 0)); then
        daily_text="${count}/不限"
    else
        daily_text="${count}/${MAX_DAILY}"
    fi

    state="$(node_health_state)"

    printf '%s | %s | 最近IP:%s | %s | 今日:%s | 失败:%s/%s | %s' \
        "$id" "$NAME" "$ip" "$enabled" "$daily_text" "$fails" "$FAIL_ROUNDS" "$state"
}

tg_list_text() {
    local id text="📋 Dynamic IP 任务列表" found=0

    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        found=1
        text+=$'\n\n'
        text+="$(node_status_line "$id")"
    done < <(node_ids)

    if ((found == 0)); then
        text+=$'\n\n'
        text+="尚未添加任务。请在服务器运行 dipguard，通过菜单添加。"
    fi

    text+=$'\n\n'
    text+="更新时间：$(date '+%F %T')"
    printf '%s\n' "$text"
}

tg_node_detail() {
    local id="$1" ip count fails pending_text daily_text ddns_timeout_str
    local health probe_detail probe_lines

    load_node "$id" || return 1

    ip="$(cat "${NODE_STATE}/last_seen_ip" 2>/dev/null || echo 未知)"
    count="$(get_daily_count)"
    fails="$(read_number_state "${NODE_STATE}/fail_rounds" 0)"
    health="$(node_health_state)"
    probe_detail="$(cat "${NODE_STATE}/last_check_detail" 2>/dev/null || echo 尚无采样)"

    case "$CHECK_MODE" in
        ping)
            probe_lines="Ping：${PING_COUNT} 次，至少回复 ${PING_MIN_REPLIES} 次
Ping 超时：${PING_TIMEOUT} 秒"
            ;;
        tcp)
            probe_lines="TCP 端口：${CHECK_PORT}
TCP 超时：${PING_TIMEOUT} 秒"
            ;;
        either|both)
            probe_lines="Ping：${PING_COUNT} 次，至少回复 ${PING_MIN_REPLIES} 次
Ping/TCP 超时：${PING_TIMEOUT} 秒
TCP 端口：${CHECK_PORT}"
            ;;
    esac

    if ((MAX_DAILY == 0)); then
        daily_text="${count}/不限"
    else
        daily_text="${count}/${MAX_DAILY}"
    fi

    if ((DDNS_WAIT_TIMEOUT == 0)); then
        ddns_timeout_str="0 (永久等待)"
    else
        ddns_timeout_str="${DDNS_WAIT_TIMEOUT} 秒"
    fi

    pending_text="无"
    if pending_exists && read_pending; then
        pending_text="等待中
旧 IP：${OLD_IP}
已等待：$(format_duration "$(($(date +%s) - STARTED_AT))")
检查周期：${CHECK_INTERVAL} 秒（与正常检测一致）"
    fi

    cat <<EOF
🖥 任务：${NAME} (${NODE_ID})

状态：$([[ "$ENABLED" == "1" ]] && echo "🟢 启用" || echo "⚪ 停用")
检测状态：${health}
最近 IP：${ip}
检测模式：${CHECK_MODE}
检测周期：${CHECK_INTERVAL} 秒
${probe_lines}
最近采样：${probe_detail}
连续失败阈值：${fails}/${FAIL_ROUNDS}
今日换 IP：${daily_text}
自动换 IP 冷却：${COOLDOWN_SECONDS} 秒

换 IP 后检查：跟随检测周期
新 IP 不通：连续 ${FAIL_ROUNDS} 轮后自动继续换
DDNS 未变超时：${ddns_timeout_str}

换 IP 状态：
${pending_text}

更新时间：$(date '+%F %T')
EOF
}

tg_node_keyboard() {
    local id="$1" toggle_text change_text change_data

    load_node "$id" || return 1

    if [[ "$ENABLED" == "1" ]]; then
        toggle_text="⏸ 停用任务"
    else
        toggle_text="▶️ 启用任务"
    fi

    if pending_exists; then
        change_text="🔁 重新提交换 IP"
        change_data="r:${id}"
    else
        change_text="🔄 立即换 IP"
        change_data="x:${id}"
    fi

    jq -cn \
        --arg id "$id" \
        --arg toggle "$toggle_text" \
        --arg change_text "$change_text" \
        --arg change_data "$change_data" \
        '{
            inline_keyboard: [
                [
                    {text:"🔍 立即检测",callback_data:("c:"+$id)},
                    {text:$change_text,callback_data:$change_data}
                ],
                [
                    {text:$toggle,callback_data:("t:"+$id)},
                    {text:"⚙️ 参数设置",callback_data:("s:"+$id)}
                ],
                [
                    {text:"🧹 清等待/失败",callback_data:("q:"+$id)},
                    {text:"0️⃣ 清零今日次数",callback_data:("d:"+$id)}
                ],
                [
                    {text:"🗑 删除任务",callback_data:("k:"+$id)}
                ],
                [
                    {text:"⬅️ 任务列表",callback_data:"l"},
                    {text:"🔄 刷新",callback_data:("n:"+$id)}
                ]
            ]
        }'
}

tg_settings_text() {
    local id="$1"
    load_node "$id" || return 1

    cat <<EOF
⚙️ 参数设置：${NAME} (${NODE_ID})

检测周期：${CHECK_INTERVAL} 秒
检测模式：${CHECK_MODE}
TCP 端口：${CHECK_PORT}
每轮 Ping：${PING_COUNT} 次
最低回复：${PING_MIN_REPLIES} 次
Ping 超时：${PING_TIMEOUT} 秒
失败轮数：${FAIL_ROUNDS}
每日上限：${MAX_DAILY}（0=不限）
换 IP 冷却：${COOLDOWN_SECONDS} 秒
DDNS 超时：${DDNS_WAIT_TIMEOUT} 秒（0=永久等待）
换 IP 后检查：跟随检测周期
新 IP 不通：连续 ${FAIL_ROUNDS} 轮后自动继续换

点击要修改的项目。
EOF
}

tg_settings_keyboard() {
    local id="$1"

    jq -cn --arg id "$id" '{
        inline_keyboard: [
            [
                {text:"⏱ 检测周期",callback_data:("p:"+$id+":check_interval")},
                {text:"🌐 检测模式",callback_data:("p:"+$id+":check_mode")}
            ],
            [
                {text:"🔌 TCP端口",callback_data:("p:"+$id+":check_port")},
                {text:"📶 Ping次数",callback_data:("p:"+$id+":ping_count")}
            ],
            [
                {text:"✅ 最低回复",callback_data:("p:"+$id+":ping_min_replies")},
                {text:"⌛ Ping超时",callback_data:("p:"+$id+":ping_timeout")}
            ],
            [
                {text:"❌ 失败轮数",callback_data:("p:"+$id+":fail_rounds")},
                {text:"🔢 每日上限",callback_data:("p:"+$id+":max_daily")}
            ],
            [
                {text:"🧊 换IP冷却",callback_data:("p:"+$id+":cooldown_seconds")},
                {text:"⏱ DDNS超时",callback_data:("p:"+$id+":ddns_wait_timeout")}
            ],
            [
                {text:"⬅️ 返回任务",callback_data:("n:"+$id)}
            ]
        ]
    }'
}

tg_setting_title() {
    case "$1" in
        max_daily) echo "每日换 IP 上限" ;;
        check_interval) echo "检测周期" ;;
        check_mode) echo "检测模式" ;;
        check_port) echo "TCP 检测端口" ;;
        ping_count) echo "每轮 Ping 次数" ;;
        ping_min_replies) echo "最低 Ping 回复数" ;;
        ping_timeout) echo "每个 Ping 超时" ;;
        fail_rounds) echo "连续失败轮数" ;;
        cooldown_seconds) echo "换 IP 冷却时间" ;;
        ddns_wait_timeout) echo "DDNS 未变超时" ;;
        *) echo "$1" ;;
    esac
}

tg_setting_value() {
    local id="$1" key="$2"
    load_node "$id" || return 1

    case "$key" in
        max_daily) echo "$MAX_DAILY" ;;
        check_interval) echo "$CHECK_INTERVAL" ;;
        check_mode) echo "$CHECK_MODE" ;;
        check_port) echo "$CHECK_PORT" ;;
        ping_count) echo "$PING_COUNT" ;;
        ping_min_replies) echo "$PING_MIN_REPLIES" ;;
        ping_timeout) echo "$PING_TIMEOUT" ;;
        fail_rounds) echo "$FAIL_ROUNDS" ;;
        cooldown_seconds) echo "$COOLDOWN_SECONDS" ;;
        ddns_wait_timeout) echo "$DDNS_WAIT_TIMEOUT" ;;
        *) return 1 ;;
    esac
}

tg_setting_text() {
    local id="$1" key="$2" title current note

    load_node "$id" || return 1
    title="$(tg_setting_title "$key")"
    current="$(tg_setting_value "$id" "$key")"

    case "$key" in
        max_daily) note="0 表示不限制每天次数。" ;;
        check_interval) note="范围 10-86400 秒。" ;;
        check_mode) note="ping：只看 Ping；tcp：只看端口；either：任一正常；both：两者都正常。" ;;
        check_port) note="范围 1-65535。" ;;
        ping_count) note="范围 1-20 次。" ;;
        ping_min_replies) note="不能大于当前每轮 Ping 次数 ${PING_COUNT}。" ;;
        ping_timeout) note="范围 1-20 秒。" ;;
        fail_rounds) note="范围 1-100 轮。" ;;
        cooldown_seconds) note="范围 0-86400 秒，0 表示无冷却。" ;;
        ddns_wait_timeout) note="范围 0-86400 秒，0 表示永久等待，超时自动重试。" ;;
        *) note="" ;;
    esac

    cat <<EOF
⚙️ ${title}

任务：${NAME} (${NODE_ID})
当前值：${current}

${note}

请选择常用值，或点击“自定义数值”。
EOF
}

tg_setting_keyboard() {
    local id="$1" key="$2"

    case "$key" in
        check_mode)
            jq -cn --arg id "$id" '{
                inline_keyboard: [
                    [
                        {text:"Ping",callback_data:("v:"+$id+":check_mode:ping")},
                        {text:"TCP",callback_data:("v:"+$id+":check_mode:tcp")}
                    ],
                    [
                        {text:"任一正常",callback_data:("v:"+$id+":check_mode:either")},
                        {text:"两者都正常",callback_data:("v:"+$id+":check_mode:both")}
                    ],
                    [
                        {text:"⬅️ 返回设置",callback_data:("s:"+$id)}
                    ]
                ]
            }'
            ;;
        check_interval)
            tg_numeric_keyboard "$id" "$key" 30 60 120 300
            ;;
        check_port)
            tg_numeric_keyboard "$id" "$key" 22 80 443 10008
            ;;
        ping_count)
            tg_numeric_keyboard "$id" "$key" 1 3 5 10
            ;;
        ping_min_replies)
            tg_numeric_keyboard "$id" "$key" 1 2 3 5
            ;;
        ping_timeout)
            tg_numeric_keyboard "$id" "$key" 1 3 5 10
            ;;
        fail_rounds)
            tg_numeric_keyboard "$id" "$key" 1 2 3 5
            ;;
        max_daily)
            tg_numeric_keyboard "$id" "$key" 0 3 5 10
            ;;
        cooldown_seconds)
            tg_numeric_keyboard "$id" "$key" 0 300 600 1800
            ;;
        ddns_wait_timeout)
            tg_numeric_keyboard "$id" "$key" 0 300 600 900
            ;;
        *)
            tg_back_main_keyboard
            ;;
    esac
}

tg_numeric_keyboard() {
    local id="$1" key="$2" v1="$3" v2="$4" v3="$5" v4="$6"

    jq -cn \
        --arg id "$id" \
        --arg key "$key" \
        --arg v1 "$v1" \
        --arg v2 "$v2" \
        --arg v3 "$v3" \
        --arg v4 "$v4" \
        '{
            inline_keyboard: [
                [
                    {text:$v1,callback_data:("v:"+$id+":"+$key+":"+$v1)},
                    {text:$v2,callback_data:("v:"+$id+":"+$key+":"+$v2)}
                ],
                [
                    {text:$v3,callback_data:("v:"+$id+":"+$key+":"+$v3)},
                    {text:$v4,callback_data:("v:"+$id+":"+$key+":"+$v4)}
                ],
                [
                    {text:"✏️ 自定义数值",callback_data:("u:"+$id+":"+$key)}
                ],
                [
                    {text:"⬅️ 返回设置",callback_data:("s:"+$id)}
                ]
            ]
        }'
}

tg_confirm_keyboard() {
    local yes_data="$1" back_data="$2"

    jq -cn \
        --arg yes "$yes_data" \
        --arg back "$back_data" \
        '{
            inline_keyboard: [
                [
                    {text:"✅ 确认执行",callback_data:$yes},
                    {text:"❌ 取消",callback_data:$back}
                ]
            ]
        }'
}

tg_set_node_value() {
    local id="$1" key="$2" value="$3"

    load_node "$id" || {
        printf '任务不存在：%s\n' "$id"
        return 1
    }

    key="$(lower_input "$key")"
    if [[ "$key" != "check_mode" ]] && is_uint "$value"; then
        value="$(canonical_uint "$value" 2>/dev/null || true)"
    fi

    case "$key" in
        max_daily)
            is_uint "$value" || { echo "必须输入 0 或正整数"; return 1; }
            MAX_DAILY="$value"
            ;;
        check_interval)
            is_uint "$value" && ((value >= 10 && value <= 86400)) ||
                { echo "范围：10-86400 秒"; return 1; }
            CHECK_INTERVAL="$value"
            ;;
        check_mode)
            case "$value" in
                ping|tcp|either|both) CHECK_MODE="$value" ;;
                *) echo "只能选择 ping/tcp/either/both"; return 1 ;;
            esac
            ;;
        check_port)
            is_uint "$value" && ((value >= 1 && value <= 65535)) ||
                { echo "范围：1-65535"; return 1; }
            CHECK_PORT="$value"
            ;;
        ping_count)
            is_uint "$value" && ((value >= 1 && value <= 20)) ||
                { echo "范围：1-20"; return 1; }
            PING_COUNT="$value"
            ((PING_MIN_REPLIES <= PING_COUNT)) || PING_MIN_REPLIES="$PING_COUNT"
            ;;
        ping_min_replies)
            is_uint "$value" && ((value >= 1 && value <= PING_COUNT)) ||
                { echo "范围：1-${PING_COUNT}"; return 1; }
            PING_MIN_REPLIES="$value"
            ;;
        ping_timeout)
            is_uint "$value" && ((value >= 1 && value <= 20)) ||
                { echo "范围：1-20 秒"; return 1; }
            PING_TIMEOUT="$value"
            ;;
        fail_rounds)
            is_uint "$value" && ((value >= 1 && value <= 100)) ||
                { echo "范围：1-100"; return 1; }
            FAIL_ROUNDS="$value"
            ;;
        cooldown_seconds)
            is_uint "$value" && ((value <= 86400)) ||
                { echo "范围：0-86400 秒"; return 1; }
            COOLDOWN_SECONDS="$value"
            ;;
        ddns_wait_timeout)
            is_uint "$value" && ((value <= 86400)) ||
                { echo "范围：0-86400 秒"; return 1; }
            DDNS_WAIT_TIMEOUT="$value"
            ;;
        *)
            echo "不支持的设置项"
            return 1
            ;;
    esac

    save_node_config "${NODE_DIR}/config"
    rm -f \
        "${NODE_STATE}/last_check" \
        "${NODE_STATE}/last_check_result" \
        "${NODE_STATE}/last_check_detail"
    printf '已更新：%s=%s\n' "$key" "$value"
}

tg_write_input_state() {
    local chat_id="$1" node_id="$2" key="$3"

    {
        printf 'INPUT_CHAT_ID=%q\n' "$chat_id"
        printf 'INPUT_NODE_ID=%q\n' "$node_id"
        printf 'INPUT_KEY=%q\n' "$key"
        printf 'INPUT_STARTED_AT=%q\n' "$(date +%s)"
    } > "${STATE_DIR}/tg_input"
    chmod 600 "${STATE_DIR}/tg_input"
}

tg_read_input_state() {
    INPUT_CHAT_ID=""
    INPUT_NODE_ID=""
    INPUT_KEY=""
    INPUT_STARTED_AT=0

    [[ -f "${STATE_DIR}/tg_input" ]] || return 1

    # 文件由脚本生成，仅 root 可写。
    # shellcheck disable=SC1090
    source "${STATE_DIR}/tg_input" || {
        rm -f "${STATE_DIR}/tg_input"
        return 1
    }

    [[ -n "$INPUT_CHAT_ID" && -n "$INPUT_NODE_ID" && -n "$INPUT_KEY" ]] ||
        return 1

    is_uint "$INPUT_STARTED_AT" || return 1

    if (( $(date +%s) - INPUT_STARTED_AT > 600 )); then
        rm -f "${STATE_DIR}/tg_input"
        return 1
    fi
}

tg_clear_input_state() {
    rm -f "${STATE_DIR}/tg_input"
}

tg_show_main() {
    local chat_id="$1" message_id="${2:-}"
    local body keyboard

    body="$(tg_main_text)"
    keyboard="$(tg_main_keyboard)"

    if [[ -n "$message_id" ]]; then
        tg_edit_message "$chat_id" "$message_id" "$body" "$keyboard"
    else
        tg_send_to "$chat_id" "$body" "$keyboard"
    fi
}

tg_show_list() {
    local chat_id="$1" message_id="${2:-}"
    local body keyboard

    body="$(tg_list_text)"
    keyboard="$(tg_tasks_keyboard)"

    if [[ -n "$message_id" ]]; then
        tg_edit_message "$chat_id" "$message_id" "$body" "$keyboard"
    else
        tg_send_to "$chat_id" "$body" "$keyboard"
    fi
}

tg_show_node() {
    local chat_id="$1" message_id="$2" id="$3"

    if ! node_exists "$id"; then
        tg_edit_message "$chat_id" "$message_id" \
            "任务不存在或已被删除。" \
            "$(tg_tasks_keyboard)"
        return
    fi

    tg_edit_message \
        "$chat_id" \
        "$message_id" \
        "$(tg_node_detail "$id")" \
        "$(tg_node_keyboard "$id")"
}

tg_show_settings() {
    local chat_id="$1" message_id="$2" id="$3"

    if ! node_exists "$id"; then
        tg_show_list "$chat_id" "$message_id"
        return
    fi

    tg_edit_message \
        "$chat_id" \
        "$message_id" \
        "$(tg_settings_text "$id")" \
        "$(tg_settings_keyboard "$id")"
}

tg_show_setting() {
    local chat_id="$1" message_id="$2" id="$3" key="$4"

    if ! node_exists "$id"; then
        tg_show_list "$chat_id" "$message_id"
        return
    fi

    tg_edit_message \
        "$chat_id" \
        "$message_id" \
        "$(tg_setting_text "$id" "$key")" \
        "$(tg_setting_keyboard "$id" "$key")"
}

tg_handle_text() {
    local chat_id="$1" text="$2"
    local result

    if [[ "$text" == "/start" || "$text" == "/start@"* ]]; then
        tg_clear_input_state
        tg_show_main "$chat_id"
        return
    fi

    if tg_read_input_state &&
       [[ "$INPUT_CHAT_ID" == "$chat_id" ]]; then

        if [[ "$(lower_input "$text")" == "cancel" || "$text" == "取消" ]]; then
            tg_clear_input_state
            tg_send_to "$chat_id" "已取消自定义设置。" "$(tg_main_keyboard)"
            return
        fi

        result="$(tg_set_node_value "$INPUT_NODE_ID" "$INPUT_KEY" "$text" 2>&1)" || {
            tg_send_to "$chat_id" \
                "设置失败：${result}

请重新输入一个有效数字，或点击取消。" \
                "$(jq -cn --arg id "$INPUT_NODE_ID" '{
                    inline_keyboard:[
                        [{text:"❌ 取消",callback_data:("s:"+$id)}]
                    ]
                }')"
            return
        }

        tg_clear_input_state
        tg_send_to "$chat_id" \
            "✅ ${result}" \
            "$(jq -cn --arg id "$INPUT_NODE_ID" '{
                inline_keyboard:[
                    [{text:"⚙️ 返回参数设置",callback_data:("s:"+$id)}],
                    [{text:"🖥 返回任务",callback_data:("n:"+$id)}]
                ]
            }')"
        return
    fi

    tg_send_to "$chat_id" \
        "请使用按钮操作。点击下面按钮打开控制面板。" \
        "$(tg_main_keyboard)"
}

tg_handle_callback() {
    local callback_id="$1" chat_id="$2" message_id="$3" data="$4"
    local action id key value ip rc result

    IFS=':' read -r action id key value <<< "$data"
    tg_answer_callback "$callback_id" "正在处理…" "false"

    case "$action" in
        m)
            tg_clear_input_state
            tg_show_main "$chat_id" "$message_id"
            ;;
        l)
            tg_clear_input_state
            tg_show_list "$chat_id" "$message_id"
            ;;
        a)
            if check_all_once; then
                tg_answer_callback "$callback_id" "全部任务检查完成" "false"
            else
                tg_answer_callback "$callback_id" "部分任务查询失败" "true"
            fi
            tg_show_list "$chat_id" "$message_id"
            ;;
        n)
            tg_clear_input_state
            tg_show_node "$chat_id" "$message_id" "$id"
            ;;
        c)
            if node_exists "$id"; then
                load_node "$id"
                if [[ "$ENABLED" != "1" ]]; then
                    tg_answer_callback "$callback_id" "任务已停用，未执行" "true"
                elif check_node "$id" 1; then
                    tg_answer_callback "$callback_id" "检测完成" "false"
                else
                    tg_answer_callback "$callback_id" "IP 查询失败" "true"
                fi
                tg_show_node "$chat_id" "$message_id" "$id"
            else
                tg_show_list "$chat_id" "$message_id"
            fi
            ;;
        x)
            if node_exists "$id"; then
                tg_edit_message \
                    "$chat_id" \
                    "$message_id" \
                    "⚠️ 确认立即提交换 IP？

任务：${id}
本操作会消耗一次换 IP 次数。" \
                    "$(tg_confirm_keyboard "xc:${id}" "n:${id}")"
            else
                tg_show_list "$chat_id" "$message_id"
            fi
            ;;
        xc)
            if ! node_exists "$id"; then
                tg_show_list "$chat_id" "$message_id"
                return
            fi

            load_node "$id"
            if pending_exists; then
                tg_edit_message \
                    "$chat_id" \
                    "$message_id" \
                    "该任务已经在等待 IP 变化。如需再次提交，请点击“重新提交换 IP”。" \
                    "$(tg_node_keyboard "$id")"
                return
            fi

            if ! ip="$(get_current_ip)"; then
                tg_answer_callback "$callback_id" "查询当前 IP 失败" "true"
                tg_show_node "$chat_id" "$message_id" "$id"
                return
            fi

            set +e
            trigger_change "$ip" "Telegram 按钮立即更换" "manual" "0" "1"
            rc=$?
            set -e

            case "$rc" in
                0) tg_answer_callback "$callback_id" "换 IP 请求已提交" "true" ;;
                2) tg_answer_callback "$callback_id" "已有请求正在等待生效" "true" ;;
                3) tg_answer_callback "$callback_id" "今日次数已达上限" "true" ;;
                5) tg_answer_callback "$callback_id" "另一个请求正在处理中" "true" ;;
                6) tg_answer_callback "$callback_id" "缺少 flock 依赖，请先安装 util-linux" "true" ;;
                *) tg_answer_callback "$callback_id" "提交失败，请查看状态" "true" ;;
            esac
            tg_show_node "$chat_id" "$message_id" "$id"
            ;;
        r)
            if node_exists "$id"; then
                tg_edit_message \
                    "$chat_id" \
                    "$message_id" \
                    "⚠️ 确认重新提交换 IP？

任务：${id}
当前等待状态会被本次请求覆盖，并再次消耗一次换 IP 次数。" \
                    "$(tg_confirm_keyboard "rc:${id}" "n:${id}")"
            else
                tg_show_list "$chat_id" "$message_id"
            fi
            ;;
        rc)
            if ! node_exists "$id"; then
                tg_show_list "$chat_id" "$message_id"
                return
            fi

            load_node "$id"
            if ! ip="$(get_current_ip)"; then
                tg_answer_callback "$callback_id" "查询当前 IP 失败" "true"
                tg_show_node "$chat_id" "$message_id" "$id"
                return
            fi

            set +e
            trigger_change "$ip" "Telegram 按钮重新提交" "manual" "1" "1"
            rc=$?
            set -e

            case "$rc" in
                0) tg_answer_callback "$callback_id" "已重新提交" "true" ;;
                3) tg_answer_callback "$callback_id" "今日次数已达上限" "true" ;;
                5) tg_answer_callback "$callback_id" "另一个请求正在处理中" "true" ;;
                6) tg_answer_callback "$callback_id" "缺少 flock 依赖，请先安装 util-linux" "true" ;;
                *) tg_answer_callback "$callback_id" "重新提交失败" "true" ;;
            esac
            tg_show_node "$chat_id" "$message_id" "$id"
            ;;
        t)
            if node_exists "$id"; then
                load_node "$id"
                if [[ "$ENABLED" == "1" ]]; then
                    set_enabled "$id" 0
                    tg_answer_callback "$callback_id" "任务已停用" "false"
                else
                    set_enabled "$id" 1
                    tg_answer_callback "$callback_id" "任务已启用" "false"
                fi
                tg_show_node "$chat_id" "$message_id" "$id"
            else
                tg_show_list "$chat_id" "$message_id"
            fi
            ;;
        s)
            tg_clear_input_state
            tg_show_settings "$chat_id" "$message_id" "$id"
            ;;
        p)
            tg_clear_input_state
            tg_show_setting "$chat_id" "$message_id" "$id" "$key"
            ;;
        v)
            result="$(tg_set_node_value "$id" "$key" "$value" 2>&1)" || {
                tg_answer_callback "$callback_id" "$result" "true"
                tg_show_setting "$chat_id" "$message_id" "$id" "$key"
                return
            }
            tg_answer_callback "$callback_id" "设置成功：${value}" "false"
            tg_show_setting "$chat_id" "$message_id" "$id" "$key"
            ;;
        u)
            if ! node_exists "$id"; then
                tg_show_list "$chat_id" "$message_id"
                return
            fi

            tg_write_input_state "$chat_id" "$id" "$key"
            tg_edit_message \
                "$chat_id" \
                "$message_id" \
                "✏️ 自定义设置

任务：${id}
项目：$(tg_setting_title "$key")

请直接回复一个数字。
输入状态 10 分钟后自动失效。" \
                "$(jq -cn --arg id "$id" '{
                    inline_keyboard:[
                        [{text:"❌ 取消",callback_data:("s:"+$id)}]
                    ]
                }')"
            ;;
        q)
            if node_exists "$id"; then
                tg_edit_message \
                    "$chat_id" \
                    "$message_id" \
                    "确认清除该任务的等待状态和连续失败计数？

不会清零今日换 IP 次数。" \
                    "$(tg_confirm_keyboard "qc:${id}" "n:${id}")"
            fi
            ;;
        qc)
            if node_exists "$id"; then
                load_node "$id"
                clear_pending
                rm -f \
                    "${NODE_STATE}/fail_rounds" \
                    "${NODE_STATE}/last_check" \
                    "${NODE_STATE}/last_check_result" \
                    "${NODE_STATE}/last_check_detail"
                tg_answer_callback "$callback_id" "运行状态已清除" "false"
                tg_show_node "$chat_id" "$message_id" "$id"
            fi
            ;;
        d)
            if node_exists "$id"; then
                tg_edit_message \
                    "$chat_id" \
                    "$message_id" \
                    "确认把该任务今日换 IP 次数清零？" \
                    "$(tg_confirm_keyboard "dc:${id}" "n:${id}")"
            fi
            ;;
        dc)
            if node_exists "$id"; then
                load_node "$id"
                set_daily_count 0
                rm -f "${NODE_STATE}/limit_notified_date"
                tg_answer_callback "$callback_id" "今日次数已清零" "false"
                tg_show_node "$chat_id" "$message_id" "$id"
            fi
            ;;
        k)
            if node_exists "$id"; then
                load_node "$id"
                tg_edit_message \
                    "$chat_id" \
                    "$message_id" \
                    "🚨 确认永久删除任务？

任务：${NAME} (${id})
配置、查询命令、换 IP 命令和运行状态都会删除。" \
                    "$(tg_confirm_keyboard "kc:${id}" "n:${id}")"
            fi
            ;;
        kc)
            if node_exists "$id"; then
                load_node "$id"
                local deleted_name="$NAME"
                rm -rf "${NODES_DIR:?}/${id}" "${STATE_DIR:?}/${id}"
                tg_answer_callback "$callback_id" "任务已删除" "true"
                tg_edit_message \
                    "$chat_id" \
                    "$message_id" \
                    "🗑 已删除任务：${deleted_name} (${id})" \
                    "$(tg_tasks_keyboard)"
            else
                tg_show_list "$chat_id" "$message_id"
            fi
            ;;
        *)
            tg_answer_callback "$callback_id" "未知按钮" "true"
            tg_show_main "$chat_id" "$message_id"
            ;;
    esac
}

tg_register_menu() {
    load_global
    [[ -n "$TG_BOT_TOKEN" ]] || return 1

    tg_curl -fsS --max-time 15 \
        -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/setMyCommands" \
        --data-urlencode 'commands=[{"command":"start","description":"打开按钮控制面板"}]' \
        >/dev/null 2>&1 || true
}

tg_poll_once() {
    local result last_update next_offset max_update rc
    local update_id kind chat_id message_id callback_id data text

    load_global

    [[ "$TG_ENABLED" == "1" &&
       "$TG_COMMANDS_ENABLED" == "1" &&
       -n "$TG_BOT_TOKEN" &&
       -n "$TG_CHAT_ID" ]] || return 0

    last_update="$(read_number_state "${STATE_DIR}/tg_last_update_id" 0)"
    next_offset=$((last_update + 1))

    set +e
    result="$(
        tg_curl -fsS --max-time 10 \
            "https://api.telegram.org/bot${TG_BOT_TOKEN}/getUpdates?offset=${next_offset}&limit=50&timeout=0" \
            2>/dev/null
    )"
    rc=$?
    set -e

    ((rc == 0)) || return 0
    max_update="$last_update"

    while IFS=$'\t' read -r \
        update_id kind chat_id message_id callback_id data text; do

        is_uint "${update_id:-}" || continue
        ((update_id > max_update)) && max_update="$update_id"

        [[ "$chat_id" == "$TG_CHAT_ID" ]] || {
            if [[ "$kind" == "callback" && -n "$callback_id" ]]; then
                tg_answer_callback "$callback_id" "无权操作此机器人" "true"
            fi
            continue
        }

        case "$kind" in
            callback)
                [[ -n "$callback_id" && -n "$message_id" && -n "$data" ]] || continue
                tg_handle_callback "$callback_id" "$chat_id" "$message_id" "$data"
                ;;
            message)
                [[ -n "$text" ]] || continue
                tg_handle_text "$chat_id" "$text"
                ;;
        esac
    done < <(
        printf '%s\n' "$result" |
        jq -r '
            .result[]? |
            if .callback_query then
                [
                    (.update_id|tostring),
                    "callback",
                    (.callback_query.message.chat.id|tostring),
                    (.callback_query.message.message_id|tostring),
                    (.callback_query.id // ""),
                    (.callback_query.data // ""),
                    ""
                ]
            elif .message then
                [
                    (.update_id|tostring),
                    "message",
                    (.message.chat.id|tostring),
                    (.message.message_id|tostring),
                    "",
                    "",
                    (.message.text // "")
                ]
            else
                empty
            end | @tsv
        ' 2>/dev/null
    )

    printf '%s\n' "$max_update" > "${STATE_DIR}/tg_last_update_id"
}


# ---------------------------------------------------------------------------
# 后台循环
# ---------------------------------------------------------------------------

daemon_loop() {
    local id now last_tg_poll

    log_msg "SYSTEM" "dipguard ${VERSION} 后台服务启动"

    while true; do
        while IFS= read -r id; do
            [[ -n "$id" ]] || continue
            check_node "$id" 0 || true
        done < <(node_ids)

        load_global
        now="$(date +%s)"
        last_tg_poll="$(read_number_state "${STATE_DIR}/last_tg_poll" 0)"

        if ((now - last_tg_poll >= TG_POLL_INTERVAL)); then
            printf '%s\n' "$now" > "${STATE_DIR}/last_tg_poll"
            tg_poll_once || true
        fi

        sleep 2
    done
}

# ---------------------------------------------------------------------------
# 菜单输入
# ---------------------------------------------------------------------------

prompt_default() {
    local text="$1" default="$2" value suffix=""
    [[ -n "$default" ]] && suffix=" ${UI_DIM}[默认: ${default}]${UI_RESET}"

    printf '%s›%s %s%s: ' "$UI_CYAN" "$UI_RESET" "$text" "$suffix" >&2
    if ! IFS= read -r value; then
        printf '%s\n' "$default"
        return 0
    fi

    value="$(trim_input "$value")"
    printf '%s\n' "${value:-$default}"
}

prompt_value() {
    local text="$1" value
    printf '%s›%s %s: ' "$UI_CYAN" "$UI_RESET" "$text" >&2
    IFS= read -r value || return 1
    trim_input "$value"
}

prompt_secret() {
    local text="$1" value
    printf '%s›%s %s: ' "$UI_CYAN" "$UI_RESET" "$text" >&2
    IFS= read -r -s value || return 1
    printf '\n' >&2
    trim_input "$value"
}

prompt_yes_no() {
    local text="$1" default="${2:-n}" value suffix

    if [[ "$default" == "y" ]]; then
        suffix="[Y/n]"
    else
        suffix="[y/N]"
    fi

    while true; do
        printf '%s›%s %s %s: ' "$UI_CYAN" "$UI_RESET" "$text" "$suffix" >&2
        IFS= read -r value || value=""
        value="$(trim_input "$value")"
        value="$(lower_input "$value")"

        if [[ -z "$value" ]]; then
            [[ "$default" == "y" ]]
            return
        fi

        case "$value" in
            y|yes|1|是) return 0 ;;
            n|no|0|否) return 1 ;;
            *) ui_error "请输入 y/n（也可以输入 是/否）。" ;;
        esac
    done
}

prompt_uint() {
    local text="$1" default="$2" value canonical
    while true; do
        value="$(prompt_default "$text" "$default")"
        if canonical="$(canonical_uint "$value" 2>/dev/null)"; then
            printf '%s\n' "$canonical"
            return
        fi
        ui_error "请输入 0 或正整数。"
    done
}

prompt_range() {
    local text="$1" default="$2" min="$3" max="$4" value
    while true; do
        value="$(prompt_uint "$text" "$default")"
        if ((value >= min && value <= max)); then
            printf '%s\n' "$value"
            return
        fi
        ui_error "请输入 ${min}-${max} 之间的数字。"
    done
}

prompt_mode() {
    local default="$1" value

    printf '%s\n' \
        "  1) Ping       只使用 ICMP" \
        "  2) TCP        只检测指定端口" \
        "  3) 任一正常   Ping 或 TCP 有一个成功即可" \
        "  4) 两者正常   Ping 和 TCP 必须都成功" >&2

    while true; do
        value="$(prompt_default "检测模式（1-4，也可输入英文）" "$default")"
        value="$(lower_input "$value")"
        case "$value" in
            1|ping) printf 'ping\n'; return ;;
            2|tcp) printf 'tcp\n'; return ;;
            3|either) printf 'either\n'; return ;;
            4|both) printf 'both\n'; return ;;
            *)
                ui_error "请选择 1-4，或输入 ping/tcp/either/both。"
                ;;
        esac
    done
}

read_command_file() {
    local file="$1"
    [[ -f "$file" ]] && cat "$file" || true
}

# ---------------------------------------------------------------------------
# 菜单：节点管理
# ---------------------------------------------------------------------------

configure_node() {
    local id="$1" editing="${2:-0}"
    local old_get="" old_change="" input

    if [[ "$editing" == "1" ]]; then
        load_node "$id"
        old_get="$(read_command_file "${NODE_DIR}/get_ip.cmd")"
        old_change="$(read_command_file "${NODE_DIR}/change_ip.cmd")"
    else
        NODE_ID="$id"
        NODE_DIR="${NODES_DIR}/${id}"
        NODE_STATE="${STATE_DIR}/${id}"

        NAME="$id"
        ENABLED=1
        MAX_DAILY=5

        CHECK_INTERVAL=10
        CHECK_MODE="ping"
        CHECK_PORT=443

        PING_COUNT=3
        PING_MIN_REPLIES=1
        PING_TIMEOUT=3
        FAIL_ROUNDS=3

        GET_IP_TIMEOUT=30
        CHANGE_CMD_TIMEOUT=90
        COOLDOWN_SECONDS=600
        DDNS_WAIT_TIMEOUT=300
    fi

    ui_header "VPS 任务高级设置" "任务标识: ${id} · 直接回车保留当前值"
    ui_info "换 IP 后按检测周期重新解析，并用相同规则验证新 IP。"
    ui_info "DDNS 未变化时保持等待；新 IP 连续失败后再次更换。"
    ui_section "1 / 4  基本信息"

    NAME="$(prompt_default "任务显示名称" "$NAME")"

    if prompt_yes_no "添加/保存后立即启用任务" "$([[ "$ENABLED" == "1" ]] && echo y || echo n)"; then
        ENABLED=1
    else
        ENABLED=0
    fi

    MAX_DAILY="$(prompt_uint "每日最多换 IP 次数，0=不限" "$MAX_DAILY")"

    ui_section "2 / 4  可用性检测"
    CHECK_INTERVAL="$(prompt_range "检测周期（秒）" "$CHECK_INTERVAL" 10 86400)"
    CHECK_MODE="$(prompt_mode "$CHECK_MODE")"

    if [[ "$CHECK_MODE" != "ping" ]]; then
        CHECK_PORT="$(prompt_range "TCP 检测端口" "$CHECK_PORT" 1 65535)"
    fi

    if [[ "$CHECK_MODE" != "tcp" ]]; then
        PING_COUNT="$(prompt_range "每轮 Ping 多少次" "$PING_COUNT" 1 20)"
        PING_MIN_REPLIES="$(
            prompt_range \
                "每轮至少收到多少个回复才算正常" \
                "$PING_MIN_REPLIES" \
                1 \
                "$PING_COUNT"
        )"
        PING_TIMEOUT="$(prompt_range "每个 Ping 最长等待几秒" "$PING_TIMEOUT" 1 20)"
    fi

    FAIL_ROUNDS="$(prompt_range "连续失败多少轮后自动换 IP" "$FAIL_ROUNDS" 1 100)"

    ui_section "3 / 4  换 IP 策略"
    GET_IP_TIMEOUT="$(prompt_range "查询当前 IP 命令超时（秒）" "$GET_IP_TIMEOUT" 1 300)"
    CHANGE_CMD_TIMEOUT="$(prompt_range "执行换 IP 命令超时（秒）" "$CHANGE_CMD_TIMEOUT" 1 600)"
    COOLDOWN_SECONDS="$(prompt_range "两次自动换 IP 最小间隔（秒），0=不限制" "$COOLDOWN_SECONDS" 0 86400)"
    DDNS_WAIT_TIMEOUT="$(prompt_range "DDNS 未更新超时时间（秒），0=永久等待" "$DDNS_WAIT_TIMEOUT" 0 86400)"

    ui_section "4 / 4  IP 来源与执行命令"
    ui_info "查询命令必须输出目标 VPS 当前公网 IPv4。"
    printf '  示例: getent ahostsv4 example.com | awk '\''NR==1{print $1}'\''\n'

    if [[ "$editing" == "1" ]]; then
        printf '%s当前查询命令%s\n  %s\n' "$UI_DIM" "$UI_RESET" "$old_get"
        input="$(prompt_value "新的查询 IP 命令（留空保留）")"
        [[ -n "$input" ]] && old_get="$input"
    else
        old_get="$(prompt_value "粘贴查询当前 IP 的一行命令")"
    fi

    [[ -n "$old_get" ]] || {
        ui_error "查询 IP 命令不能为空，未保存任何修改。"
        return 1
    }

    echo
    if [[ "$editing" == "1" ]]; then
        printf '%s当前换 IP 命令%s\n  %s\n' "$UI_DIM" "$UI_RESET" "$old_change"
        input="$(prompt_value "新的换 IP 命令（留空保留）")"
        [[ -n "$input" ]] && old_change="$input"
    else
        old_change="$(prompt_value "粘贴执行换 IP 的一行命令")"
    fi

    [[ -n "$old_change" ]] || {
        ui_error "换 IP 命令不能为空，未保存任何修改。"
        return 1
    }

    validate_change_command "$old_change" || {
        ui_error "换 IP 命令没有保存，请修正后重试。"
        return 1
    }

    ui_section "配置摘要"
    printf '  名称          %s\n' "$NAME"
    printf '  检测          每 %s 秒 · %s · 连续失败 %s 轮\n' \
        "$CHECK_INTERVAL" "$CHECK_MODE" "$FAIL_ROUNDS"
    printf '  每日上限      %s\n' "$([[ "$MAX_DAILY" == "0" ]] && echo 不限 || echo "${MAX_DAILY} 次")"
    printf '  换 IP 冷却    %s 秒\n' "$COOLDOWN_SECONDS"
    printf '  DDNS 超时     %s\n' "$([[ "$DDNS_WAIT_TIMEOUT" == "0" ]] && echo 永久等待 || echo "${DDNS_WAIT_TIMEOUT} 秒")"

    if ! prompt_yes_no "保存以上配置" "y"; then
        ui_warn "已取消，配置未修改。"
        return 0
    fi

    mkdir -p "$NODE_DIR" "$NODE_STATE"
    chmod 700 "$NODE_DIR" "$NODE_STATE"

    save_node_config "${NODE_DIR}/config"
    printf '%s\n' "$old_get" > "${NODE_DIR}/get_ip.cmd"
    printf '%s\n' "$old_change" > "${NODE_DIR}/change_ip.cmd"
    chmod 600 "${NODE_DIR}/get_ip.cmd" "${NODE_DIR}/change_ip.cmd"

    rm -f \
        "${NODE_STATE}/last_check" \
        "${NODE_STATE}/last_check_result" \
        "${NODE_STATE}/last_check_detail"
    ui_ok "任务配置已保存：$id"
}

quick_add_node() {
    local id source_type source_value get_cmd change_cmd quoted_value current_ip

    ui_header "快速添加 VPS 任务" "按步骤填写；输入错误会停留在当前项"
    ui_info "需要准备：DDNS/查询方式，以及可成功执行的换 IP 命令。"
    ui_section "1 / 4  任务信息"

    while true; do
        id="$(prompt_value "任务标识（例如 hkt）")"

        valid_node_id "$id" || {
            ui_error "只能使用字母、数字、下划线和短横线，最长 32 位。"
            continue
        }

        node_exists "$id" && {
            ui_error "任务 ${id} 已存在，请换一个标识。"
            continue
        }

        break
    done

    NODE_ID="$id"
    NODE_DIR="${NODES_DIR}/${id}"
    NODE_STATE="${STATE_DIR}/${id}"

    NAME="$(prompt_default "任务显示名称" "$id")"
    ENABLED=1
    MAX_DAILY="$(prompt_uint "每天最多换 IP 次数，0=不限" "5")"

    # 快速向导只询问决定准确性的关键检测项，其余使用稳妥默认值。
    CHECK_INTERVAL=10
    CHECK_MODE="either"
    CHECK_PORT=22
    PING_COUNT=3
    PING_MIN_REPLIES=1
    PING_TIMEOUT=3
    FAIL_ROUNDS=3
    GET_IP_TIMEOUT=30
    CHANGE_CMD_TIMEOUT=90
    COOLDOWN_SECONDS=600
    DDNS_WAIT_TIMEOUT=300

    ui_section "2 / 4  可用性检测"
    ui_info "很多 VPS 会禁 Ping，因此默认采用“Ping 或 TCP 任一成功”。"
    CHECK_MODE="$(prompt_mode "$CHECK_MODE")"
    if [[ "$CHECK_MODE" != "ping" ]]; then
        CHECK_PORT="$(prompt_range "目标 VPS 上确认开放的 TCP 端口" "$CHECK_PORT" 1 65535)"
    fi

    ui_section "3 / 4  当前 IP 来源"
    printf '%s\n' \
        "  1) 动态域名 / DDNS（推荐）" \
        "  2) 服务商返回目标 VPS IP 的 HTTP 接口" \
        "  3) 自定义查询命令（高级）"

    while true; do
        source_type="$(prompt_value "请选择 1-3")"
        case "$source_type" in
            1|2|3) break ;;
            *) ui_error "只能输入 1、2 或 3。" ;;
        esac
    done

    case "$source_type" in
        1)
            while true; do
                source_value="$(prompt_value "动态域名，例如 hkt.example.com")"
                if [[ "$source_value" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*[A-Za-z0-9]$ ]] ||
                    [[ "$source_value" =~ ^[A-Za-z0-9]$ ]]; then
                    break
                fi
                ui_error "域名格式不正确，不要带协议、路径或端口。"
            done

            quoted_value="$(printf '%q' "$source_value")"
            get_cmd="getent ahostsv4 ${quoted_value} | awk '!seen[\$1]++ {print \$1}'"
            ;;

        2)
            ui_warn "接口必须返回目标 VPS 的 IP；普通“查询本机 IP”网址不能使用。"
            while true; do
                source_value="$(prompt_value "服务商查询目标 VPS IP 的接口 URL")"

                case "$source_value" in
                    https://myip.ipip.net*|http://myip.ipip.net*|\
                    https://ddns.oray.com/checkip*|http://ddns.oray.com/checkip*|\
                    https://ip.3322.net*|http://ip.3322.net*|\
                    https://4.ipw.cn*|http://4.ipw.cn*|\
                    https://v4.yinghualuo.cn/bejson*|http://v4.yinghualuo.cn/bejson*)
                        ui_error "该网址返回调用者本机 IP，不是目标 VPS IP。"
                        continue
                        ;;
                    http://*|https://*)
                        break
                        ;;
                    *)
                        ui_error "URL 必须以 http:// 或 https:// 开头。"
                        ;;
                esac
            done

            quoted_value="$(printf '%q' "$source_value")"
            get_cmd="curl -4fsSL --max-time 20 ${quoted_value}"
            ;;

        3)
            get_cmd="$(prompt_value "粘贴查询当前 IP 的一行命令")"
            [[ -n "$get_cmd" ]] || {
                ui_error "查询命令不能为空。"
                return 1
            }
            ;;
    esac

    ui_section "4 / 4  换 IP 命令"
    ui_info "请粘贴已经在当前服务器验证成功的一行命令。"
    change_cmd="$(prompt_value "换 IP 命令")"

    [[ -n "$change_cmd" ]] || {
        ui_error "换 IP 命令不能为空。"
        return 1
    }

    validate_change_command "$change_cmd" || {
        ui_error "命令没有保存，请修正后重新添加任务。"
        return 1
    }

    mkdir -p "$NODE_DIR" "$NODE_STATE"
    chmod 700 "$NODE_DIR" "$NODE_STATE"

    save_node_config "${NODE_DIR}/config"
    printf '%s\n' "$get_cmd" > "${NODE_DIR}/get_ip.cmd"
    printf '%s\n' "$change_cmd" > "${NODE_DIR}/change_ip.cmd"
    chmod 600 "${NODE_DIR}/get_ip.cmd" "${NODE_DIR}/change_ip.cmd"

    rm -f \
        "${NODE_STATE}/last_check" \
        "${NODE_STATE}/last_check_result" \
        "${NODE_STATE}/last_check_detail"

    ui_section "连接测试"
    ui_info "正在查询目标 VPS 当前 IP…"

    load_node "$id"

    if current_ip="$(get_current_ip)"; then
        printf '%s\n' "$current_ip" > "${NODE_STATE}/last_seen_ip"

        ui_ok "任务已添加并查询到有效 IPv4。"
        printf '  任务       %s (%s)\n' "$NAME" "$id"
        printf '  当前 IP    %s\n' "$current_ip"
        printf '  检测       每 %s 秒 · %s' "$CHECK_INTERVAL" "$CHECK_MODE"
        [[ "$CHECK_MODE" != "ping" ]] && printf ' · TCP %s' "$CHECK_PORT"
        printf '\n'
        printf '  触发条件   连续失败 %s 轮\n' "$FAIL_ROUNDS"
        printf '  每日上限   %s\n' "$([[ "$MAX_DAILY" == "0" ]] && echo 不限 || echo "${MAX_DAILY} 次")"
    else
        ui_warn "查询命令没有返回有效 IPv4。"
        printf '%s查询命令输出%s\n' "$UI_DIM" "$UI_RESET"
        cat "${NODE_STATE}/last_get_ip_error" 2>/dev/null || true

        if prompt_yes_no "仍然保留这个未通过测试的任务" "n"; then
            ui_warn "任务已保留但不会被视为已验证，请修正后重新测试。"
        else
            rm -rf "${NODE_DIR:?}" "${NODE_STATE:?}"
            ui_info "已取消添加，没有保留无效任务。"
        fi
    fi
}

select_node() {
    local ids=() id index ip state

    while IFS= read -r id; do
        [[ -n "$id" ]] && ids+=("$id")
    done < <(node_ids)

    if ((${#ids[@]} == 0)); then
        echo "尚未添加任务。"
        return 1
    fi

    ui_section "选择任务"
    for index in "${!ids[@]}"; do
        load_node "${ids[$index]}"
        ip="$(cat "${NODE_STATE}/last_seen_ip" 2>/dev/null || echo 未知)"
        if pending_exists; then
            state="等待新 IP"
        elif [[ "$ENABLED" == "1" ]]; then
            state="运行中"
        else
            state="已停用"
        fi
        printf '  %2d) %s (%s)\n' \
            "$((index + 1))" \
            "$NAME" \
            "${ids[$index]}"
        printf '      %s · %s\n' "$ip" "$state"
    done
    printf '   0) 返回\n'

    while true; do
        index="$(prompt_value "输入任务编号")"
        [[ "$index" == "0" ]] && return 1

        if is_uint "$index"; then
            index="$(canonical_uint "$index" 2>/dev/null || true)"
            [[ -n "$index" ]] || {
                ui_error "编号过大。"
                continue
            }
            if ((index >= 1 && index <= ${#ids[@]})); then
                SELECTED_NODE="${ids[$((index - 1))]}"
                return 0
            fi
        fi

        ui_error "请输入 0-${#ids[@]} 之间的编号。"
    done
}

edit_node() {
    select_node || return
    configure_node "$SELECTED_NODE" 1
}

delete_node() {
    local answer

    select_node || return
    load_node "$SELECTED_NODE"

    answer="$(prompt_value "删除 ${NAME} (${SELECTED_NODE})，输入 DELETE 确认")"

    [[ "$answer" == "DELETE" ]] || {
        ui_info "已取消。"
        return
    }

    rm -rf "${NODES_DIR:?}/${SELECTED_NODE}" "${STATE_DIR:?}/${SELECTED_NODE}"
    ui_ok "任务已删除。"
}

enable_node_menu() {
    select_node || return
    set_enabled "$SELECTED_NODE" 1
    echo "任务已启用。"
}

disable_node_menu() {
    select_node || return
    set_enabled "$SELECTED_NODE" 0
    echo "任务已停用。"
}

node_status_text() {
    local id="$1" ip count fails task_state change_state daily_text last_check
    local health probe_detail

    load_node "$id"

    ip="$(cat "${NODE_STATE}/last_seen_ip" 2>/dev/null || echo "-")"
    count="$(get_daily_count)"
    fails="$(read_number_state "${NODE_STATE}/fail_rounds" 0)"

    if ((MAX_DAILY == 0)); then
        daily_text="${count}/不限"
    else
        daily_text="${count}/${MAX_DAILY}"
    fi

    task_state="$([[ "$ENABLED" == "1" ]] && echo 启用 || echo 停用)"
    health="$(node_health_state)"
    probe_detail="$(cat "${NODE_STATE}/last_check_detail" 2>/dev/null || true)"

    if pending_exists && read_pending; then
        change_state="等待新IP $(format_duration "$(($(date +%s) - STARTED_AT))")"
    else
        change_state="无"
    fi

    last_check="$(read_number_state "${NODE_STATE}/last_check" 0)"

    printf '%s%s%s  %s%s%s\n' "$UI_BOLD" "$NAME" "$UI_RESET" "$UI_DIM" "(${id})" "$UI_RESET"
    printf '  任务       %s\n' "$task_state"
    printf '  检测状态   %s\n' "$health"
    printf '  最近 IP    %s\n' "$ip"
    printf '  检测       %s · 每 %s 秒' "$CHECK_MODE" "$CHECK_INTERVAL"
    [[ "$CHECK_MODE" != "ping" ]] && printf ' · TCP %s' "$CHECK_PORT"
    printf '\n'
    printf '  失败轮数   %s/%s\n' "$fails" "$FAIL_ROUNDS"
    printf '  今日换 IP  %s\n' "$daily_text"
    printf '  换 IP 状态 %s\n' "$change_state"
    [[ -n "$probe_detail" ]] && printf '  最近采样   %s\n' "$probe_detail"
    if ((last_check > 0)); then
        printf '  上次检测   %s\n' "$(date -d "@${last_check}" '+%F %T' 2>/dev/null || echo "$last_check")"
    else
        printf '  上次检测   尚未检测\n'
    fi
}

list_nodes() {
    local id found=0

    ui_header "任务状态" "状态文件中的最近结果；“立即测试”可获取实时结果"

    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        found=$((found + 1))
        ((found > 1)) && printf '%s\n' "────────────────────────────────────────────────────────"
        node_status_text "$id"
    done < <(node_ids)

    ((found > 0)) || ui_info "尚未添加任务。"
}

test_node() {
    local ip result probe_text

    select_node || return
    load_node "$SELECTED_NODE"

    ui_header "实时测试" "任务: ${NAME} (${SELECTED_NODE})"
    ui_info "正在执行 IP 查询命令…"
    if ! ip="$(get_current_ip)"; then
        ui_error "没有查询到有效 IPv4。原始输出如下："
        cat "${NODE_STATE}/last_get_ip_error" 2>/dev/null || true
        return 1
    fi

    if check_reachable "$ip"; then
        result="正常"
    else
        result="失败"
    fi

    probe_text="$(last_probe_summary)"
    [[ -n "$LAST_PROBE_ERROR" ]] && probe_text+="；${LAST_PROBE_ERROR}"

    [[ "$result" == "正常" ]] && ui_ok "实时检测正常" || ui_error "实时检测失败"
    printf '  当前 IP    %s\n' "$ip"
    printf '  检测模式   %s\n' "$CHECK_MODE"
    printf '  探测明细   %s\n' "$probe_text"
    printf '  采样时间   %s\n' "$(date '+%F %T')"
}

manual_check_menu() {
    select_node || return
    load_node "$SELECTED_NODE"
    if [[ "$ENABLED" != "1" ]]; then
        ui_warn "任务已停用，本次不会运行自动检查；请使用“实时测试”做无副作用探测。"
        return 1
    fi
    if check_node "$SELECTED_NODE" 1; then
        ui_ok "自动检查已完成，失败计数和换 IP 策略已按结果处理。"
    else
        ui_error "自动检查未完成：当前 IP 查询失败，请查看任务状态中的原始错误。"
        return 1
    fi
}

manual_change_menu() {
    local ip rc retry_pending=0 change_command after_ip

    select_node || return
    load_node "$SELECTED_NODE"

    change_command="$(read_command_file "${NODE_DIR}/change_ip.cmd")"
    ui_header "换 IP 诊断与执行" "任务: ${NAME} (${SELECTED_NODE})"

    if ! show_change_command_info \
        "$change_command" \
        "${NODE_STATE}/last_change_output"; then
        if ! prompt_yes_no "命令检查未通过，仍然尝试真实执行" "n"; then
            ui_warn "已取消，本次没有执行换 IP。"
            return 1
        fi
    fi

    if pending_exists; then
        ui_warn "该任务已经在等待新 IP。重复提交会再次消耗一次每日次数。"
        if ! prompt_yes_no "是否明确重新提交一次换 IP" "n"; then
            ui_info "已取消。"
            return
        fi
        retry_pending=1
    else
        retry_pending=0
    fi

    ui_section "执行前确认"
    printf '  最近 IP     %s\n' \
        "$(cat "${NODE_STATE}/last_seen_ip" 2>/dev/null || echo 未知)"
    printf '  今日次数    %s\n' \
        "$(get_daily_count)/$([[ "$MAX_DAILY" == "0" ]] && echo 不限 || echo "$MAX_DAILY")"
    printf '  命令超时    %s 秒\n' "$CHANGE_CMD_TIMEOUT"

    if ! prompt_yes_no "确认执行上面的真实换 IP 命令" "n"; then
        ui_info "已取消，命令没有执行。"
        return
    fi

    if ! ip="$(get_current_ip)"; then
        ui_error "查询当前 IP 失败，未执行。"
        cat "${NODE_STATE}/last_get_ip_error" 2>/dev/null || true
        return 1
    fi

    printf '  执行前 IP    %s\n' "$ip"

    set +e
    trigger_change \
        "$ip" \
        "本机菜单手动立即更换" \
        "manual" \
        "$retry_pending" \
        "1"
    rc=$?
    set -e

    case "$rc" in
        0)
            ui_ok "命令返回成功，已进入等待新 IP 验证。"
            ;;
        2)
            ui_warn "已有换 IP 请求正在等待生效，本次未重复提交。"
            ;;
        3)
            ui_warn "今日次数已达上限，命令没有执行。"
            ;;
        5)
            ui_warn "另一个换 IP 请求正在处理，本次未重复提交。"
            ;;
        6)
            ui_error "缺少 flock，未执行换 IP；请先安装 util-linux。"
            ;;
        *)
            ui_error "命令未成功提交，退出码：${rc}。"
            ;;
    esac

    ui_section "执行结果"
    if ((rc == 2 || rc == 3 || rc == 5 || rc == 6)); then
        printf '  本次没有执行换 IP 命令。\n'
    elif [[ -s "${NODE_STATE}/last_change_output" ]]; then
        tail -n 30 "${NODE_STATE}/last_change_output" | sed 's/^/  /'
    else
        printf '  （命令没有输出）\n'
    fi

    if ((rc == 0)); then
        ui_info "后台会按检测周期重新查询 IP；看到新 IP 后还会继续执行 Ping/TCP 验证。"

        ui_info "正在立即复查一次当前 IP…"
        if after_ip="$(get_current_ip)"; then
            if [[ "$after_ip" == "$ip" ]]; then
                ui_warn "命令返回 0，但 IP 仍是 ${after_ip}。这不代表换 IP 已生效，后台会继续等待并按超时策略重试。"
            else
                ui_ok "已看到 IP 变化：${ip} → ${after_ip}，等待后台完成可用性验证。"
            fi
        else
            ui_warn "命令已返回 0，但立即复查 IP 失败；后台会继续等待。"
        fi
    fi
}

reset_node_state() {
    select_node || return
    load_node "$SELECTED_NODE"

    if ! prompt_yes_no "清除等待状态和连续失败计数？每日次数不会清零" "n"; then
        return
    fi

    clear_pending
    rm -f \
        "${NODE_STATE}/fail_rounds" \
        "${NODE_STATE}/last_check" \
        "${NODE_STATE}/last_check_result" \
        "${NODE_STATE}/last_check_detail"
    ui_ok "运行状态已清除。"
}

reset_daily_count_menu() {
    select_node || return
    load_node "$SELECTED_NODE"

    if ! prompt_yes_no "确定把该任务今日换 IP 次数清零" "n"; then
        return
    fi

    set_daily_count 0
    rm -f "${NODE_STATE}/limit_notified_date"
    echo "今日次数已清零。"
}

# ---------------------------------------------------------------------------
# 菜单：Telegram
# ---------------------------------------------------------------------------

telegram_setup() {
    local value detected masked mode current_mode

    load_global

    echo
    echo "Telegram 是可选模块。关闭后不影响任务检测、自动换 IP 和本机菜单。"
    echo
    echo "  0) 关闭 Telegram"
    echo "  1) Telegram 直连"
    echo "  2) Telegram 通过 HTTP/SOCKS5 代理"
    echo

    if [[ "$TG_ENABLED" != "1" ]]; then
        current_mode=0
    elif [[ "$TG_PROXY_ENABLED" == "1" ]]; then
        current_mode=2
    else
        current_mode=1
    fi

    while true; do
        mode="$(prompt_default "请选择 Telegram 连接模式" "$current_mode")"
        case "$mode" in
            0|1|2)
                break
                ;;
            *)
                echo "只能输入 0、1 或 2。"
                ;;
        esac
    done

    if [[ "$mode" == "0" ]]; then
        TG_ENABLED=0
        TG_COMMANDS_ENABLED=0
        TG_PROXY_ENABLED=0
        save_global
        rm -f \
            "${STATE_DIR}/tg_last_update_id" \
            "${STATE_DIR}/last_tg_poll" \
            "${STATE_DIR}/tg_input"

        echo
        echo "Telegram 已关闭。"
        echo "任务检测、换 IP、次数限制和本机菜单继续正常运行。"
        return 0
    fi

    TG_ENABLED=1

    if [[ "$mode" == "2" ]]; then
        TG_PROXY_ENABLED=1

        echo
        echo "支持的代理格式："
        echo "  socks5h://1.2.3.4:1080"
        echo "  socks5h://user:pass@1.2.3.4:1080"
        echo "  http://user:pass@1.2.3.4:3128"
        echo
        echo "本机已有 sing-box、Xray 等代理客户端时，也可以填写："
        echo "  socks5h://127.0.0.1:1080"
        echo
        echo "推荐 socks5h://，域名解析也交给代理处理。"

        if [[ -n "$TG_PROXY_URL" ]]; then
            echo "当前代理：$(tg_proxy_description)"
        else
            echo "当前代理：未设置"
        fi

        value="$(prompt_value "输入代理 URL（留空保留当前值）")"
        [[ -n "$value" ]] && TG_PROXY_URL="$value"

        case "$TG_PROXY_URL" in
            http://*|https://*|socks5://*|socks5h://*)
                ;;
            *)
                echo "代理 URL 无效，Telegram 配置未保存。"
                echo "示例：socks5h://user:pass@1.2.3.4:1080"
                return 1
                ;;
        esac
    else
        TG_PROXY_ENABLED=0
    fi

    echo
    if [[ -n "$TG_BOT_TOKEN" ]]; then
        masked="${TG_BOT_TOKEN:0:8}******${TG_BOT_TOKEN: -4}"
        echo "当前 Bot Token：$masked"
    else
        echo "当前 Bot Token：未设置"
    fi

    value="$(prompt_secret "粘贴新的 Bot Token（留空保留）")"
    [[ -n "$value" ]] && TG_BOT_TOKEN="$value"

    if [[ -z "$TG_BOT_TOKEN" ]]; then
        echo "Bot Token 不能为空，Telegram 配置未保存。"
        return 1
    fi

    # 先临时保存连接模式和 Token，确保国内机器可通过刚设置的代理自动获取 Chat ID。
    save_global

    echo
    echo "当前 Chat ID：${TG_CHAT_ID:-未设置}"
    value="$(prompt_value "新的 Chat ID（auto 自动获取，留空保留）")"

    if [[ "$value" == "auto" ]]; then
        echo "请先给机器人发送一次 /start，然后按回车继续。"
        read -r _
        if detected="$(tg_get_latest_chat_id)" && [[ -n "$detected" ]]; then
            TG_CHAT_ID="$detected"
            echo "已获取 Chat ID：$TG_CHAT_ID"
        else
            echo "未获取到 Chat ID。"
            echo "请检查 Bot Token、代理连接，并确认已经给机器人发送 /start。"
        fi
    elif [[ -n "$value" ]]; then
        if is_int "$value"; then
            TG_CHAT_ID="$value"
        else
            echo "Chat ID 格式不正确，本次保留原值。"
        fi
    fi

    if [[ -z "$TG_CHAT_ID" ]]; then
        echo "Chat ID 尚未设置。可以先保存，之后重新进入 Telegram 设置。"
    fi

    if prompt_yes_no \
        "允许通过 Telegram 按钮执行检测、启停、设置、删除和换 IP" \
        "$([[ "$TG_COMMANDS_ENABLED" == "1" ]] && echo y || echo n)"; then
        TG_COMMANDS_ENABLED=1
    else
        TG_COMMANDS_ENABLED=0
    fi

    TG_POLL_INTERVAL="$(
        prompt_range \
            "Telegram 按钮请求每隔多少秒检查一次" \
            "$TG_POLL_INTERVAL" \
            2 \
            60
    )"

    save_global
    rm -f \
        "${STATE_DIR}/tg_last_update_id" \
        "${STATE_DIR}/last_tg_poll" \
        "${STATE_DIR}/tg_input"

    tg_register_menu || true

    echo
    echo "Telegram 配置已保存。"
    echo "连接方式：$(tg_proxy_description)"

    if [[ -n "$TG_CHAT_ID" ]]; then
        echo "可以选择菜单中的“测试 Telegram 通知”。"
        echo "给机器人发送 /start 后会显示按钮控制面板。"
    fi
}
telegram_show_buttons_info() {
    cat <<'EOF'

Telegram 按钮面板功能：

  • 查看全部任务
  • 查看单个任务状态
  • 立即检测一个任务
  • 立即检查全部任务
  • 立即换 IP
  • 等待期间明确重新提交换 IP
  • 启用或停用任务
  • 修改全部检测参数
  • 清除等待状态和失败计数
  • 清零今日换 IP 次数
  • 删除任务

常用参数直接点按钮选择。
需要特殊数值时，点击“自定义数值”，然后只回复一个数字。

首次使用只需要给机器人发送一次：
  /start

Telegram 可以完全关闭，也可以选择直连或代理连接。
国内服务器不能直连时，可配置 HTTP、HTTPS、SOCKS5 或 SOCKS5H
代理。代理只用于 Telegram，不会影响 VPS 检测、查询 IP 和
服务商换 IP API。

本机已运行 sing-box、Xray 等代理客户端时，可以使用本地监听地址，
例如 socks5h://127.0.0.1:1080。脚本不会强制安装代理应用。

添加新 VPS 任务仍在服务器菜单中完成，因为需要保存查询 IP
命令和换 IP 命令，不建议通过 Telegram 发送这些敏感内容。
EOF
}

# ---------------------------------------------------------------------------
# 安装、服务、卸载
# ---------------------------------------------------------------------------

install_service() {
    local packages=(
        bash
        curl
        jq
        iputils-ping
        netcat-openbsd
        util-linux
        coreutils
        grep
        gawk
    )
    local newly_missing=()
    local pkg
    local source_file=""
    local temp_source=""

    echo "检查依赖……"

    for pkg in "${packages[@]}"; do
        if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null |
            grep -q '^install ok installed$'; then
            newly_missing+=("$pkg")
        fi
    done

    # 在 apt 执行前记录原本缺失的依赖。即使后续安装阶段失败，
    # 彻底卸载时也能知道哪些包可能由本脚本安装。
    if ((${#newly_missing[@]} > 0)); then
        {
            [[ -f "$INSTALLED_PACKAGES_FILE" ]] &&
                cat "$INSTALLED_PACKAGES_FILE"
            printf '%s\n' "${newly_missing[@]}"
        } | awk 'NF && !seen[$0]++' > "${INSTALLED_PACKAGES_FILE}.tmp"

        mv -f "${INSTALLED_PACKAGES_FILE}.tmp" "$INSTALLED_PACKAGES_FILE"
        chmod 600 "$INSTALLED_PACKAGES_FILE"
    fi

    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"

    if [[ -n "$SELF_PATH" &&
          -f "$SELF_PATH" &&
          -r "$SELF_PATH" &&
          "$SELF_PATH" != "$BIN_PATH" ]]; then
        source_file="$SELF_PATH"
    elif [[ "$SELF_PATH" == "$BIN_PATH" && -f "$BIN_PATH" ]]; then
        source_file="$BIN_PATH"
    else
        echo "检测到当前通过 bash <(curl ...) 运行，重新下载脚本本体……"
        temp_source="$(mktemp /tmp/dipguard-install.XXXXXX)"

        if ! curl -fsSL \
            --retry 3 \
            --retry-delay 2 \
            --connect-timeout 15 \
            "$SCRIPT_URL" \
            -o "$temp_source"; then
            rm -f "$temp_source"
            echo "下载脚本本体失败，安装已停止。"
            return 1
        fi

        if ! bash -n "$temp_source"; then
            rm -f "$temp_source"
            echo "下载到的脚本语法校验失败，安装已停止。"
            return 1
        fi

        source_file="$temp_source"
    fi

    if [[ "$source_file" != "$BIN_PATH" ]]; then
        install -m 700 "$source_file" "$BIN_PATH"
    else
        chmod 700 "$BIN_PATH"
    fi

    [[ -n "$temp_source" ]] && rm -f "$temp_source"

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Dynamic IP VPS Guard
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN_PATH} --daemon
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now "$APP"

    if ! systemctl is-active --quiet "$APP"; then
        echo "服务启动失败，最近日志如下："
        journalctl -u "$APP" -n 50 --no-pager || true
        return 1
    fi

    echo "安装/更新完成，服务已启动。"
    echo "程序路径：$BIN_PATH"
    echo "配置目录：$BASE_DIR"
    echo "以后打开菜单：dipguard"
}

service_status() {
    systemctl status "$APP" --no-pager -l || true
}

show_logs() {
    local line

    if [[ ! -f "$LOG_FILE" ]]; then
        ui_warn "日志文件尚不存在：$LOG_FILE"
        return 1
    fi

    ui_header "运行日志" "最近 120 条；颜色按成功、等待、失败分类"
    if [[ ! -s "$LOG_FILE" ]]; then
        ui_info "日志为空。"
    else
        while IFS= read -r line; do
            format_log_line "$line"
        done < <(tail -n 120 "$LOG_FILE")
    fi

    if ! prompt_yes_no "继续实时跟踪新日志" "n"; then
        return 0
    fi

    ui_info "实时跟踪中，按 Ctrl+C 返回菜单。"
    set +e
    tail -n 0 -f "$LOG_FILE" |
        while IFS= read -r line; do
            format_log_line "$line"
        done
    set -e
}

remove_program_files() {
    systemctl disable --now "$APP" 2>/dev/null || true
    pkill -f "^${BIN_PATH} --daemon$" 2>/dev/null || true
    pkill -f "^/bin/bash ${BIN_PATH} --daemon$" 2>/dev/null || true
    pkill -f "^/usr/bin/bash ${BIN_PATH} --daemon$" 2>/dev/null || true

    rm -f \
        "/etc/systemd/system/${APP}.service" \
        "/etc/systemd/system/${APP}.timer" \
        "/etc/systemd/system/${APP}@.service" \
        "/etc/systemd/system/${APP}@.timer" \
        "/etc/systemd/system/multi-user.target.wants/${APP}.service" \
        "/etc/systemd/system/timers.target.wants/${APP}.timer" \
        "/lib/systemd/system/${APP}.service" \
        "/usr/lib/systemd/system/${APP}.service" \
        "/etc/cron.d/${APP}" \
        "/etc/logrotate.d/${APP}" \
        "$BIN_PATH"

    systemctl daemon-reload
    systemctl reset-failed "$APP" 2>/dev/null || true
}

uninstall_all() {
    local choice answer
    local tracked_packages=()

    echo
    echo "请选择卸载方式："
    echo "  1) 只卸载程序，保留 VPS 任务和 Telegram 配置"
    echo "  2) 彻底卸载，删除程序、服务、配置、状态和日志"
    echo "  0) 取消"
    echo

    while true; do
        choice="$(prompt_value "请选择 0-2")"
        case "$choice" in
            0)
                echo "已取消。"
                return 0
                ;;
            1|2)
                break
                ;;
            *)
                ui_error "只能输入 0、1 或 2。"
                ;;
        esac
    done

    if [[ "$choice" == "1" ]]; then
        if ! prompt_yes_no "确认卸载程序并保留配置" "n"; then
            echo "已取消。"
            return 0
        fi

        remove_program_files
        echo "程序和 systemd 服务已删除。"
        echo "保留配置：$BASE_DIR"
        echo "保留状态：$STATE_DIR"
        echo "保留日志：$LOG_FILE"
        return 0
    fi

    answer="$(prompt_value "彻底删除全部数据，输入 DELETE 确认")"
    if [[ "$answer" != "DELETE" ]]; then
        echo "确认内容不正确，已取消。"
        return 0
    fi

    if [[ -f "$INSTALLED_PACKAGES_FILE" ]]; then
        mapfile -t tracked_packages < <(
            awk 'NF && !seen[$0]++' "$INSTALLED_PACKAGES_FILE"
        )
    fi

    remove_program_files

    rm -rf \
        "$BASE_DIR" \
        "$STATE_DIR" \
        "$LOG_FILE" \
        "/run/${APP}" \
        "/var/run/${APP}"

    find /tmp -maxdepth 1 -type f \
        \( -name 'dipguard-install.*' -o -name 'dipguard-self.*' \) \
        -delete 2>/dev/null || true

    echo "程序、systemd 服务、配置、状态和日志已彻底删除。"

    if ((${#tracked_packages[@]} > 0)); then
        echo
        echo "以下依赖在安装时被记录为原本未安装："
        printf '  %s\n' "${tracked_packages[@]}"

        if prompt_yes_no "同时卸载这些由脚本安装的依赖" "n"; then
            DEBIAN_FRONTEND=noninteractive \
                apt-get purge -y "${tracked_packages[@]}" || true
            DEBIAN_FRONTEND=noninteractive \
                apt-get autoremove -y --purge || true
            echo "已尝试卸载记录的依赖并清理孤立依赖。"
        else
            echo "依赖包已保留，避免影响其他程序。"
        fi
    else
        echo
        echo "没有依赖安装记录，因此不会自动卸载系统软件包。"
    fi
}

# ---------------------------------------------------------------------------
# 菜单
# ---------------------------------------------------------------------------

menu_overview() {
    local id total=0 enabled=0 pending=0 service_state="未安装"

    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        total=$((total + 1))
        load_node "$id" || continue
        [[ "$ENABLED" == "1" ]] && enabled=$((enabled + 1))
        pending_exists && pending=$((pending + 1))
    done < <(node_ids)

    if command_available systemctl && systemctl is-active --quiet "$APP" 2>/dev/null; then
        service_state="运行中"
    elif command_available systemctl && systemctl list-unit-files "${APP}.service" 2>/dev/null |
        grep -q "${APP}.service"; then
        service_state="已停止"
    fi

    printf '任务 %s 个 · 启用 %s 个 · 等待新 IP %s 个 · 服务 %s\n' \
        "$total" "$enabled" "$pending" "$service_state"
}

menu() {
    local choice normalized_choice

    while true; do
        [[ -t 1 ]] && clear

        printf '\n%s╭────────────────────────────────────────────────────────╮%s\n' "$UI_BLUE" "$UI_RESET"
        printf '%s│%s  %s动态 IP 守护%s  v%s\n' "$UI_BLUE" "$UI_RESET" "$UI_BOLD" "$UI_RESET" "$VERSION"
        printf '%s│%s  %s\n' "$UI_BLUE" "$UI_RESET" "$(menu_overview)"
        printf '%s╰────────────────────────────────────────────────────────╯%s\n' "$UI_BLUE" "$UI_RESET"

        ui_section "主菜单"
        printf '  %s1)%s  安装 / 更新服务\n' "$UI_CYAN" "$UI_RESET"
        printf '  %s2)%s  新建 VPS 任务\n' "$UI_CYAN" "$UI_RESET"
        printf '  %s3)%s  编辑 VPS 任务\n' "$UI_CYAN" "$UI_RESET"
        printf '  %s4)%s  删除 VPS 任务\n' "$UI_CYAN" "$UI_RESET"
        printf '  %s5)%s  启用 VPS 任务\n' "$UI_CYAN" "$UI_RESET"
        printf '  %s6)%s  停用 VPS 任务\n' "$UI_CYAN" "$UI_RESET"
        printf '  %s7)%s  任务总览\n' "$UI_CYAN" "$UI_RESET"
        printf '  %s8)%s  单次实时探测（不改状态）\n' "$UI_CYAN" "$UI_RESET"
        printf '  %s9)%s  执行一次自动检查\n' "$UI_CYAN" "$UI_RESET"
        printf ' %s10)%s  手动更换 IP\n' "$UI_CYAN" "$UI_RESET"
        printf ' %s11)%s  清除运行状态\n' "$UI_CYAN" "$UI_RESET"
        printf ' %s12)%s  重置今日换 IP 次数\n' "$UI_CYAN" "$UI_RESET"
        printf ' %s13)%s  Telegram 通知设置\n' "$UI_CYAN" "$UI_RESET"
        printf ' %s14)%s  发送 Telegram 测试\n' "$UI_CYAN" "$UI_RESET"
        printf ' %s15)%s  Telegram 使用说明\n' "$UI_CYAN" "$UI_RESET"
        printf ' %s16)%s  检查全部任务\n' "$UI_CYAN" "$UI_RESET"
        printf ' %s17)%s  查看运行日志\n' "$UI_CYAN" "$UI_RESET"
        printf ' %s18)%s  查看服务状态\n' "$UI_CYAN" "$UI_RESET"
        printf ' %s19)%s  重启后台服务\n' "$UI_CYAN" "$UI_RESET"
        printf ' %s20)%s  停止后台服务\n' "$UI_CYAN" "$UI_RESET"
        printf ' %s21)%s  启动后台服务\n' "$UI_CYAN" "$UI_RESET"
        printf ' %s22)%s  卸载程序\n' "$UI_CYAN" "$UI_RESET"
        printf '  %s0)%s  退出\n' "$UI_CYAN" "$UI_RESET"
        printf '\n%s提示：10 会先检查命令，再确认真实执行；17 可查看最近日志并实时跟踪。%s\n' \
            "$UI_DIM" "$UI_RESET"

        if ! choice="$(prompt_value "请输入编号（0-22）")"; then
            printf '\n'
            exit 0
        fi
        if normalized_choice="$(canonical_uint "$choice" 2>/dev/null)"; then
            choice="$normalized_choice"
        fi

        case "$choice" in
            1)
                install_service
                ;;
            2)
                if quick_add_node; then
                    systemctl restart "$APP" 2>/dev/null || true
                fi
                ;;
            3)
                if edit_node; then
                    systemctl restart "$APP" 2>/dev/null || true
                fi
                ;;
            4)
                if delete_node; then
                    systemctl restart "$APP" 2>/dev/null || true
                fi
                ;;
            5)
                enable_node_menu || true
                ;;
            6)
                disable_node_menu || true
                ;;
            7)
                list_nodes
                ;;
            8)
                test_node || true
                ;;
            9)
                manual_check_menu || true
                ;;
            10)
                manual_change_menu || true
                ;;
            11)
                reset_node_state || true
                ;;
            12)
                reset_daily_count_menu || true
                ;;
            13)
                if telegram_setup; then
                    systemctl restart "$APP" 2>/dev/null || true
                fi
                ;;
            14)
                tg_test || true
                ;;
            15)
                telegram_show_buttons_info
                ;;
            16)
                check_all_once || ui_warn "部分任务检查失败，请查看状态或日志。"
                ;;
            17)
                show_logs
                ;;
            18)
                service_status
                ;;
            19)
                if systemctl restart "$APP"; then
                    ui_ok "后台服务已重启。"
                else
                    ui_error "重启失败，请先安装程序或查看服务状态。"
                fi
                ;;
            20)
                if systemctl stop "$APP"; then
                    ui_ok "后台服务已停止。"
                else
                    ui_error "停止失败，请查看服务状态。"
                fi
                ;;
            21)
                if systemctl start "$APP"; then
                    ui_ok "后台服务已启动。"
                else
                    ui_error "启动失败，请先安装程序或查看服务状态。"
                fi
                ;;
            22)
                uninstall_all
                ;;
            0)
                exit 0
                ;;
            *)
                ui_error "无效选项，请输入 0-22。"
                ;;
        esac

        pause_menu
    done
}

# ---------------------------------------------------------------------------
# 主入口
# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
用法：$0 [选项]

  --daemon     运行后台监控循环
  --check-all  立即检查全部启用任务
  --version    显示版本
  --help       显示帮助

不带选项时打开交互菜单。
EOF
}

# 只读参数不要求 root，也不应创建 /etc、/var 下的运行目录。
case "${1:-}" in
    --version)
        echo "$VERSION"
        exit 0
        ;;
    --help|-h)
        usage
        exit 0
        ;;
esac

require_root
ensure_dirs

case "${1:-}" in
    --daemon)
        daemon_loop
        ;;
    --check-all)
        check_all_once
        ;;
    "")
        menu
        ;;
    *)
        usage >&2
        exit 1
        ;;
esac
