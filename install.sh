#!/usr/bin/env bash
# dipguard - 国内 Debian 监控机上的动态 IP VPS 任务管理器
# 功能：
# - 多 VPS 任务添加、修改、删除、启用、停用
# - 每台任务独立设置检测周期、Ping 次数、失败轮数、每日换 IP 上限等
# - DDNS 未变化时不重复提交；新 IP 连续检测失败后自动继续换 IP
# - Telegram 通知与远程命令控制
#
# 运行：
#   bash dipguard.sh
#   dipguard --daemon
#   dipguard --check-all

set -Eeuo pipefail
export LC_ALL=C

APP="dipguard"
VERSION="3.7.0"

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

is_int() {
    [[ "${1:-}" =~ ^-?[0-9]+$ ]]
}

is_ipv4() {
    local ip="${1:-}" a b c d
    IFS='.' read -r a b c d <<< "$ip"

    [[ -n "${a:-}" && -n "${b:-}" && -n "${c:-}" && -n "${d:-}" ]] || return 1
    [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ &&
       "$c" =~ ^[0-9]+$ && "$d" =~ ^[0-9]+$ ]] || return 1

    ((10#$a <= 255 && 10#$b <= 255 && 10#$c <= 255 && 10#$d <= 255))
}

extract_ipv4() {
    local text="$1" ip
    while IFS= read -r ip; do
        if is_ipv4 "$ip"; then
            printf '%s\n' "$ip"
            return 0
        fi
    done < <(printf '%s\n' "$text" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' || true)

    return 1
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

    is_uint "$value" || value="$default"
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
    source "$GLOBAL_CONF"

    is_uint "${TG_ENABLED:-}" || TG_ENABLED=0
    is_uint "${TG_COMMANDS_ENABLED:-}" || TG_COMMANDS_ENABLED=1
    is_uint "${TG_POLL_INTERVAL:-}" || TG_POLL_INTERVAL=3
    is_uint "${TG_PROXY_ENABLED:-}" || TG_PROXY_ENABLED=0
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

    # 文件由脚本生成，仅 root 可写。
    # shellcheck disable=SC1090
    source "${NODE_DIR}/config"

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
    } > "$file"
    chmod 600 "$file"
}

set_enabled() {
    local id="$1" value="$2"
    load_node "$id" || return 1
    ENABLED="$value"
    save_node_config "${NODE_DIR}/config"

    if [[ "$value" == "1" ]]; then
        rm -f "${NODE_STATE}/last_check"
        log_msg "$NAME" "任务已启用"
    else
        log_msg "$NAME" "任务已停用"
    fi
}

run_saved_command() {
    local command_file="$1" timeout_seconds="$2"
    local command

    command="$(cat "$command_file")"
    timeout --signal=TERM --kill-after=5 "${timeout_seconds}s" bash -lc "$command"
}

get_current_ip() {
    local output rc

    set +e
    output="$(run_saved_command "${NODE_DIR}/get_ip.cmd" "$GET_IP_TIMEOUT" 2>&1)"
    rc=$?
    set -e

    if ((rc != 0)); then
        printf '%s\n' "$output" > "${NODE_STATE}/last_get_ip_error"
        chmod 600 "${NODE_STATE}/last_get_ip_error"
        return 1
    fi

    extract_ipv4 "$output"
}

# ---------------------------------------------------------------------------
# 检测
# ---------------------------------------------------------------------------

ping_reply_count() {
    local ip="$1" output received

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

ping_ok() {
    local ip="$1" replies
    replies="$(ping_reply_count "$ip")"
    ((replies >= PING_MIN_REPLIES))
}

tcp_ok() {
    local ip="$1"
    timeout "$((PING_TIMEOUT + 1))" \
        nc -z -w "$PING_TIMEOUT" "$ip" "$CHECK_PORT" >/dev/null 2>&1
}

check_reachable() {
    local ip="$1"

    case "$CHECK_MODE" in
        ping)
            ping_ok "$ip"
            ;;
        tcp)
            tcp_ok "$ip"
            ;;
        either)
            ping_ok "$ip" || tcp_ok "$ip"
            ;;
        both)
            ping_ok "$ip" && tcp_ok "$ip"
            ;;
        *)
            return 2
            ;;
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
    source "${NODE_STATE}/pending"

    is_ipv4 "$OLD_IP" && is_uint "$STARTED_AT"
}

clear_pending_validation() {
    rm -f         "${NODE_STATE}/pending_candidate_ip"         "${NODE_STATE}/pending_candidate_failures"         "${NODE_STATE}/pending_limit_wait_date"
}

clear_pending() {
    rm -f "${NODE_STATE}/pending" "${NODE_STATE}/last_pending_poll"
    clear_pending_validation
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
当前 IP：$(cat "${NODE_STATE}/last_seen_ip" 2>/dev/null || echo 未知)
自动换 IP 已暂停到次日计数重置。"
}

# ---------------------------------------------------------------------------
# 换 IP
# ---------------------------------------------------------------------------

trigger_change() {
    local current_ip="$1"
    local reason="$2"
    local mode="${3:-auto}"
    local allow_pending_retry="${4:-0}"
    local ignore_cooldown="${5:-0}"
    local count now last_trigger elapsed output rc count_text

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
    log_msg "$NAME" "提交换 IP；旧 IP：$current_ip；原因：$reason"

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

    count=$((count + 1))
    set_daily_count "$count"
    printf '%s\n' "$now" > "${NODE_STATE}/last_trigger"
    printf '%s\n' "$now" > "${NODE_STATE}/last_pending_poll"

    # 手动或自动重试时覆盖旧 pending，从本次提交重新计时。
    write_pending "$current_ip" "$now" "$reason"
    clear_pending_validation
    printf '0\n' > "${NODE_STATE}/fail_rounds"

    if ((MAX_DAILY == 0)); then
        log_msg "$NAME" "请求已提交，今日第 ${count} 次（不限次数）；无限期等待 IP 变化"
        count_text="${count}（不限次数）"
    else
        log_msg "$NAME" "请求已提交，今日 ${count}/${MAX_DAILY}；无限期等待 IP 变化"
        count_text="${count}/${MAX_DAILY}"
    fi

    tg_notify "🔄 已提交换 IP
任务：${NAME} (${NODE_ID})
旧 IP：${current_ip}
原因：${reason}
今日次数：${count_text}
状态：DDNS 未变化时只等待；新 IP 连续 ${FAIL_ROUNDS} 轮不通会自动继续换 IP。"

    return 0
}

poll_pending() {
    local current_ip now last_poll elapsed
    local candidate_ip candidate_failures rc today blocked_date

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
        log_msg "$NAME" "DDNS 仍为旧 IP：$current_ip；已等待 $(format_duration "$elapsed")"
        return 0
    fi

    # DDNS 已变化，使用任务原有的 Ping/TCP 规则验证新 IP。
    if check_reachable "$current_ip"; then
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

    printf '%s\n' "$candidate_failures" >         "${NODE_STATE}/pending_candidate_failures"

    log_msg "$NAME"         "新 IP 检测失败：$current_ip；连续 ${candidate_failures}/${FAIL_ROUNDS} 轮"

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

    log_msg "$NAME"         "新 IP $current_ip 连续 ${candidate_failures} 轮不可用，自动继续更换 IP"

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
    local current_ip now last_check fail_rounds replies lock_fd rc

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
        log_msg "$NAME" "查询命令未返回有效 IPv4；为避免误换，本轮跳过"

        flock -u "$lock_fd"
        exec {lock_fd}>&-
        return 1
    fi

    printf '%s\n' "$current_ip" > "${NODE_STATE}/last_seen_ip"

    fail_rounds="$(read_number_state "${NODE_STATE}/fail_rounds" 0)"

    if check_reachable "$current_ip"; then
        if ((fail_rounds > 0)); then
            log_msg "$NAME" "检测恢复：$current_ip；连续失败 ${fail_rounds} -> 0"
        fi
        printf '0\n' > "${NODE_STATE}/fail_rounds"
    else
        fail_rounds=$((fail_rounds + 1))
        printf '%s\n' "$fail_rounds" > "${NODE_STATE}/fail_rounds"

        replies="-"
        if [[ "$CHECK_MODE" != "tcp" ]]; then
            replies="$(ping_reply_count "$current_ip")"
        fi

        log_msg "$NAME" "检测失败：$current_ip；连续失败 ${fail_rounds}/${FAIL_ROUNDS}；Ping 回复 ${replies}/${PING_COUNT}"

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

    if pending_exists && read_pending; then
        state="等待新IP $(format_duration "$(($(date +%s) - STARTED_AT))")"
    else
        state="正常"
    fi

    printf '%s | %s | IP:%s | %s | 今日:%s | 失败:%s/%s | %s' \
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
    local id="$1" ip count fails pending_text daily_text

    load_node "$id" || return 1

    ip="$(cat "${NODE_STATE}/last_seen_ip" 2>/dev/null || echo 未知)"
    count="$(get_daily_count)"
    fails="$(read_number_state "${NODE_STATE}/fail_rounds" 0)"

    if ((MAX_DAILY == 0)); then
        daily_text="${count}/不限"
    else
        daily_text="${count}/${MAX_DAILY}"
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
当前 IP：${ip}
检测模式：${CHECK_MODE}
检测周期：${CHECK_INTERVAL} 秒
Ping：${PING_COUNT} 次，至少回复 ${PING_MIN_REPLIES} 次
Ping 超时：${PING_TIMEOUT} 秒
连续失败阈值：${fails}/${FAIL_ROUNDS}
TCP 端口：${CHECK_PORT}
今日换 IP：${daily_text}
自动换 IP 冷却：${COOLDOWN_SECONDS} 秒
换 IP 后检查：每 ${CHECK_INTERVAL} 秒验证
新 IP 失败策略：连续 ${FAIL_ROUNDS} 轮不通自动继续换

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
换 IP 后检查：跟随检测周期
新 IP 不通：连续 ${FAIL_ROUNDS} 轮后自动继续换
换 IP 冷却：${COOLDOWN_SECONDS} 秒

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
                {text:"🧊 换IP冷却",callback_data:("p:"+$id+":cooldown_seconds")}
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

    key="${key,,}"

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
        *)
            echo "不支持的设置项"
            return 1
            ;;
    esac

    save_node_config "${NODE_DIR}/config"
    rm -f "${NODE_STATE}/last_check"
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
    source "${STATE_DIR}/tg_input"

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

        if [[ "${text,,}" == "cancel" || "$text" == "取消" ]]; then
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
            check_all_once || true
            tg_answer_callback "$callback_id" "全部任务检查完成" "false"
            tg_show_list "$chat_id" "$message_id"
            ;;
        n)
            tg_clear_input_state
            tg_show_node "$chat_id" "$message_id" "$id"
            ;;
        c)
            if node_exists "$id"; then
                check_node "$id" 1 || true
                tg_answer_callback "$callback_id" "检测完成" "false"
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
                3) tg_answer_callback "$callback_id" "今日次数已达上限" "true" ;;
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
                rm -f "${NODE_STATE}/fail_rounds" "${NODE_STATE}/last_check"
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
    local text="$1" default="$2" value
    read -r -p "${text} [${default}]: " value
    printf '%s\n' "${value:-$default}"
}

prompt_yes_no() {
    local text="$1" default="${2:-n}" value suffix

    if [[ "$default" == "y" ]]; then
        suffix="[Y/n]"
    else
        suffix="[y/N]"
    fi

    while true; do
        read -r -p "${text} ${suffix}: " value
        value="${value,,}"

        if [[ -z "$value" ]]; then
            [[ "$default" == "y" ]]
            return
        fi

        case "$value" in
            y|yes) return 0 ;;
            n|no) return 1 ;;
            *) echo "请输入 y 或 n。" ;;
        esac
    done
}

prompt_uint() {
    local text="$1" default="$2" value
    while true; do
        value="$(prompt_default "$text" "$default")"
        if is_uint "$value"; then
            printf '%s\n' "$value"
            return
        fi
        echo "请输入 0 或正整数。"
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
        echo "请输入 ${min}-${max}。"
    done
}

prompt_mode() {
    local default="$1" value
    while true; do
        value="$(prompt_default "检测模式：ping / tcp / either / both" "$default")"
        case "$value" in
            ping|tcp|either|both)
                printf '%s\n' "$value"
                return
                ;;
            *)
                echo "只能输入 ping、tcp、either 或 both。"
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
    fi

    echo
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║                 VPS 任务高级设置                    ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo
    echo "说明：换 IP 后按正常检测周期解析 DDNS，并用相同的"
    echo "      Ping/TCP 规则验证新 IP。DDNS 未变时只等待；"
    echo "      新 IP 连续失败达到阈值后会自动继续更换。"
    echo
    echo "── ① 基本信息 ───────────────────────────────────────"

    NAME="$(prompt_default "任务显示名称" "$NAME")"

    if prompt_yes_no "添加/保存后立即启用任务" "$([[ "$ENABLED" == "1" ]] && echo y || echo n)"; then
        ENABLED=1
    else
        ENABLED=0
    fi

    MAX_DAILY="$(prompt_uint "每日最多换 IP 次数，0=不限" "$MAX_DAILY")"

    echo
    echo "── ② 可用性检测 ─────────────────────────────────────"
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

    echo
    echo "── ③ 换 IP 策略 ─────────────────────────────────────"
    GET_IP_TIMEOUT="$(prompt_range "查询当前 IP 命令超时（秒）" "$GET_IP_TIMEOUT" 1 300)"
    CHANGE_CMD_TIMEOUT="$(prompt_range "执行换 IP 命令超时（秒）" "$CHANGE_CMD_TIMEOUT" 1 600)"
    COOLDOWN_SECONDS="$(prompt_range "两次自动换 IP 最小间隔（秒），0=不限制" "$COOLDOWN_SECONDS" 0 86400)"

    echo
    echo "── ④ IP 来源与执行命令 ──────────────────────────────"
    echo "查询命令必须输出目标 VPS 当前公网 IPv4。"
    echo "已使用 DDNS 时，可使用："
    echo "  getent ahostsv4 你的域名 | awk 'NR==1{print \$1}'"
    echo

    if [[ "$editing" == "1" ]]; then
        echo "当前查询命令：$old_get"
        read -r -p "新的查询 IP 命令，直接回车保留: " input
        [[ -n "$input" ]] && old_get="$input"
    else
        read -r -p "粘贴查询当前 IP 的一行命令: " old_get
    fi

    [[ -n "$old_get" ]] || {
        echo "查询 IP 命令不能为空。"
        return 1
    }

    echo
    if [[ "$editing" == "1" ]]; then
        echo "当前换 IP 命令：$old_change"
        read -r -p "新的换 IP 命令，直接回车保留: " input
        [[ -n "$input" ]] && old_change="$input"
    else
        read -r -p "粘贴执行换 IP 的一行命令: " old_change
    fi

    [[ -n "$old_change" ]] || {
        echo "换 IP 命令不能为空。"
        return 1
    }

    mkdir -p "$NODE_DIR" "$NODE_STATE"
    chmod 700 "$NODE_DIR" "$NODE_STATE"

    save_node_config "${NODE_DIR}/config"
    printf '%s\n' "$old_get" > "${NODE_DIR}/get_ip.cmd"
    printf '%s\n' "$old_change" > "${NODE_DIR}/change_ip.cmd"
    chmod 600 "${NODE_DIR}/get_ip.cmd" "${NODE_DIR}/change_ip.cmd"

    rm -f "${NODE_STATE}/last_check"
    echo "任务配置已保存：$id"
}

quick_add_node() {
    local id source_type source_value get_cmd change_cmd quoted_value current_ip
    local keep_failed

    echo
    echo "========================================================"
    echo "              快速添加 VPS 任务"
    echo "========================================================"
    echo "只需填写：名称、DDNS/查询方式、每日上限、换 IP 命令。"
    echo "检测参数自动使用推荐值，之后可在菜单 3 中调整。"
    echo

    while true; do
        read -r -p "任务标识（例如 hkt）: " id

        valid_node_id "$id" || {
            echo "只能使用字母、数字、下划线和短横线，最长 32 位。"
            continue
        }

        node_exists "$id" && {
            echo "该任务已经存在。"
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

    # 推荐默认参数，不在快速向导里逐项询问。
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

    echo
    echo "请选择如何查询这台 VPS 当前的动态 IP："
    echo "  1) 动态域名 / DDNS（最简单，推荐）"
    echo "  2) 服务商查询 IP 的 HTTP 接口"
    echo "  3) 自定义查询命令（高级）"
    echo

    while true; do
        read -r -p "请选择 [1-3]: " source_type
        case "$source_type" in
            1|2|3) break ;;
            *) echo "只能输入 1、2 或 3。" ;;
        esac
    done

    case "$source_type" in
        1)
            while true; do
                read -r -p "输入动态域名，例如 hkt.example.com: " source_value
                if [[ "$source_value" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*[A-Za-z0-9]$ ]] ||
                   [[ "$source_value" =~ ^[A-Za-z0-9]$ ]]; then
                    break
                fi
                echo "域名格式不正确，不要带 http://、路径或端口。"
            done

            quoted_value="$(printf '%q' "$source_value")"
            get_cmd="getent ahostsv4 ${quoted_value} | awk 'NR==1{print \$1}'"
            ;;

        2)
            while true; do
                read -r -p "输入服务商查询当前 IP 的接口 URL: " source_value

                case "$source_value" in
                    https://myip.ipip.net*|http://myip.ipip.net*|\
                    https://ddns.oray.com/checkip*|http://ddns.oray.com/checkip*|\
                    https://ip.3322.net*|http://ip.3322.net*|\
                    https://4.ipw.cn*|http://4.ipw.cn*|\
                    https://v4.yinghualuo.cn/bejson*|http://v4.yinghualuo.cn/bejson*)
                        echo "这个网址返回的是调用者本机 IP，不是目标 VPS IP，不能使用。"
                        continue
                        ;;
                    http://*|https://*)
                        break
                        ;;
                    *)
                        echo "必须以 http:// 或 https:// 开头。"
                        ;;
                esac
            done

            quoted_value="$(printf '%q' "$source_value")"
            get_cmd="curl -4fsSL --max-time 20 ${quoted_value}"
            ;;

        3)
            read -r -p "粘贴查询当前 IP 的一行命令: " get_cmd
            [[ -n "$get_cmd" ]] || {
                echo "查询命令不能为空。"
                return 1
            }
            ;;
    esac

    echo
    echo "粘贴你已经可以成功执行的“更换 IP”一行命令。"
    read -r -p "换 IP 命令: " change_cmd

    [[ -n "$change_cmd" ]] || {
        echo "换 IP 命令不能为空。"
        return 1
    }

    mkdir -p "$NODE_DIR" "$NODE_STATE"
    chmod 700 "$NODE_DIR" "$NODE_STATE"

    save_node_config "${NODE_DIR}/config"
    printf '%s\n' "$get_cmd" > "${NODE_DIR}/get_ip.cmd"
    printf '%s\n' "$change_cmd" > "${NODE_DIR}/change_ip.cmd"
    chmod 600 "${NODE_DIR}/get_ip.cmd" "${NODE_DIR}/change_ip.cmd"

    rm -f "${NODE_STATE}/last_check"

    echo
    echo "正在测试 IP 获取……"

    load_node "$id"

    if current_ip="$(get_current_ip)"; then
        printf '%s\n' "$current_ip" > "${NODE_STATE}/last_seen_ip"

        echo "✅ 添加成功"
        echo "任务：$NAME ($id)"
        echo "当前 IP：$current_ip"
        echo "每日上限：$MAX_DAILY（0=不限）"
        echo
        echo "推荐默认检测："
        echo "  每 10 秒检测一轮"
        echo "  每轮 Ping 3 次"
        echo "  至少 1 次回复即正常"
        echo "  连续失败 3 轮后换 IP"
        echo "  换 IP 后继续按每 10 秒周期解析 DDNS"
        echo "  新 IP 通过相同 Ping/TCP 检测后才算完成"
        echo "  新 IP 连续 3 轮仍不通会自动继续换 IP"
        echo "  DDNS 仍为旧 IP 时不会重复提交"
    else
        echo "⚠️ 任务已保存，但当前没有查询到有效 IPv4。"
        echo "查询命令输出："
        cat "${NODE_STATE}/last_get_ip_error" 2>/dev/null || true
        echo
        echo "请检查动态域名或服务商接口，然后使用菜单 8 重新测试。"
    fi
}

add_node() {
    local id

    while true; do
        read -r -p "任务标识（例如 vps1）: " id

        valid_node_id "$id" || {
            echo "只能使用字母、数字、下划线和短横线，最长 32 位。"
            continue
        }

        node_exists "$id" && {
            echo "该任务已存在。"
            continue
        }

        break
    done

    configure_node "$id" 0
}

select_node() {
    local ids=() id index

    while IFS= read -r id; do
        [[ -n "$id" ]] && ids+=("$id")
    done < <(node_ids)

    if ((${#ids[@]} == 0)); then
        echo "尚未添加任务。"
        return 1
    fi

    echo
    for index in "${!ids[@]}"; do
        load_node "${ids[$index]}"
        printf '  %d) %s (%s) [%s]\n' \
            "$((index + 1))" \
            "$NAME" \
            "${ids[$index]}" \
            "$([[ "$ENABLED" == "1" ]] && echo 启用 || echo 停用)"
    done

    read -r -p "请选择任务编号: " index

    is_uint "$index" || return 1
    ((index >= 1 && index <= ${#ids[@]})) || return 1

    SELECTED_NODE="${ids[$((index - 1))]}"
}

edit_node() {
    select_node || return
    configure_node "$SELECTED_NODE" 1
}

delete_node() {
    local answer

    select_node || return
    load_node "$SELECTED_NODE"

    read -r -p "确定删除任务 $NAME ($SELECTED_NODE)？输入 DELETE 确认: " answer

    [[ "$answer" == "DELETE" ]] || {
        echo "已取消。"
        return
    }

    rm -rf "${NODES_DIR:?}/${SELECTED_NODE}" "${STATE_DIR:?}/${SELECTED_NODE}"
    echo "任务已删除。"
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
    local id="$1" ip count fails task_state change_state daily_text

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

    if pending_exists && read_pending; then
        change_state="等待新IP $(format_duration "$(($(date +%s) - STARTED_AT))")"
    else
        change_state="无"
    fi

    printf '%-11s %-16s %-15s %-6s %-10s %-9s %-20s\n' \
        "$id" \
        "$NAME" \
        "$ip" \
        "$task_state" \
        "$daily_text" \
        "${fails}/${FAIL_ROUNDS}" \
        "$change_state"
}

list_nodes() {
    local id found=0

    echo
    printf '%-11s %-16s %-15s %-6s %-10s %-9s %-20s\n' \
        "标识" "名称" "最近IP" "任务" "今日次数" "失败轮数" "换IP状态"
    printf '%s\n' "------------------------------------------------------------------------------------------"

    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        found=1
        node_status_text "$id"
    done < <(node_ids)

    ((found == 1)) || echo "尚未添加任务。"
}

test_node() {
    local ip replies

    select_node || return
    load_node "$SELECTED_NODE"

    echo "查询当前 IP……"
    if ! ip="$(get_current_ip)"; then
        echo "查询失败。命令输出："
        cat "${NODE_STATE}/last_get_ip_error" 2>/dev/null || true
        return 1
    fi

    echo "当前 IP：$ip"
    echo "执行检测……"

    if check_reachable "$ip"; then
        echo "结果：正常"
    else
        echo "结果：失败"
    fi

    if [[ "$CHECK_MODE" != "tcp" ]]; then
        replies="$(ping_reply_count "$ip")"
        echo "Ping 回复：${replies}/${PING_COUNT}"
        echo "最低要求：${PING_MIN_REPLIES}/${PING_COUNT}"
    fi
}

manual_check_menu() {
    select_node || return
    check_node "$SELECTED_NODE" 1 || true
    echo "检查完成，请查看状态或日志。"
}

manual_change_menu() {
    local ip rc answer

    select_node || return
    load_node "$SELECTED_NODE"

    if pending_exists; then
        echo "该任务已经在等待 IP 变化。"
        if ! prompt_yes_no "是否明确重新提交一次换 IP" "n"; then
            echo "已取消。"
            return
        fi
        retry_pending=1
    else
        retry_pending=0
    fi

    echo "今日已换：$(get_daily_count)；每日上限：${MAX_DAILY}（0=不限）"

    if ! prompt_yes_no "立即提交换 IP" "n"; then
        echo "已取消。"
        return
    fi

    if ! ip="$(get_current_ip)"; then
        echo "查询当前 IP 失败，未执行。"
        return 1
    fi

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
        0) echo "换 IP 请求已提交。" ;;
        3) echo "今日次数已达上限，未提交。" ;;
        *) echo "未提交或执行失败，请查看日志。" ;;
    esac
}

reset_node_state() {
    select_node || return
    load_node "$SELECTED_NODE"

    if ! prompt_yes_no "清除等待状态和连续失败计数？每日次数不会清零" "n"; then
        return
    fi

    clear_pending
    rm -f "${NODE_STATE}/fail_rounds" "${NODE_STATE}/last_check"
    echo "运行状态已清除。"
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

        read -r -p "输入代理 URL，直接回车保留当前值: " value
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

    read -r -p "粘贴新的 Bot Token，直接回车保留: " value
    [[ -n "$value" ]] && TG_BOT_TOKEN="$value"

    if [[ -z "$TG_BOT_TOKEN" ]]; then
        echo "Bot Token 不能为空，Telegram 配置未保存。"
        return 1
    fi

    # 先临时保存连接模式和 Token，确保国内机器可通过刚设置的代理自动获取 Chat ID。
    save_global

    echo
    echo "当前 Chat ID：${TG_CHAT_ID:-未设置}"
    read -r -p "输入新的 Chat ID；输入 auto 自动获取；直接回车保留: " value

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
    echo
    echo "按 Ctrl+C 退出实时日志。"
    sleep 1
    tail -n 100 -f "$LOG_FILE"
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
        read -r -p "请输入选项 [0-2]: " choice
        case "$choice" in
            0)
                echo "已取消。"
                return 0
                ;;
            1|2)
                break
                ;;
            *)
                echo "只能输入 0、1 或 2。"
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

    read -r -p "彻底删除全部数据，请输入 DELETE 确认: " answer
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

menu() {
    local choice

    while true; do
        clear || true

        cat <<EOF
========================================================
        Dynamic IP Guard v${VERSION}
========================================================
  1) 安装/更新程序并启动服务

  2) 快速添加 VPS 任务（推荐）
  3) 高级修改 VPS 任务及全部参数
  4) 删除 VPS 任务
  5) 启用 VPS 任务
  6) 停用 VPS 任务
  7) 查看任务列表与状态

  8) 立即测试一个任务
  9) 立即检查一个任务
 10) 立即提交/重新提交换 IP
 11) 清除等待状态和失败计数
 12) 清零一个任务今日换 IP 次数

 13) 设置/关闭 Telegram 机器人
 14) 测试 Telegram 连接与通知
 15) 查看 Telegram 按钮说明

 16) 立即检查全部启用任务
 17) 查看实时日志
 18) 查看服务状态
 19) 重启后台服务
 20) 停止后台服务
 21) 启动后台服务
 22) 卸载程序

  0) 退出
========================================================
EOF

        read -r -p "请输入选项 [0-22]: " choice

        case "$choice" in
            1)
                install_service
                ;;
            2)
                quick_add_node
                systemctl restart "$APP" 2>/dev/null || true
                ;;
            3)
                edit_node
                systemctl restart "$APP" 2>/dev/null || true
                ;;
            4)
                delete_node
                systemctl restart "$APP" 2>/dev/null || true
                ;;
            5)
                enable_node_menu
                ;;
            6)
                disable_node_menu
                ;;
            7)
                list_nodes
                ;;
            8)
                test_node
                ;;
            9)
                manual_check_menu
                ;;
            10)
                manual_change_menu
                ;;
            11)
                reset_node_state
                ;;
            12)
                reset_daily_count_menu
                ;;
            13)
                telegram_setup
                systemctl restart "$APP" 2>/dev/null || true
                ;;
            14)
                tg_test
                ;;
            15)
                telegram_show_buttons_info
                ;;
            16)
                check_all_once
                ;;
            17)
                show_logs
                ;;
            18)
                service_status
                ;;
            19)
                systemctl restart "$APP"
                echo "后台服务已重启。"
                ;;
            20)
                systemctl stop "$APP"
                echo "后台服务已停止。"
                ;;
            21)
                systemctl start "$APP"
                echo "后台服务已启动。"
                ;;
            22)
                uninstall_all
                ;;
            0)
                exit 0
                ;;
            *)
                echo "无效选项。"
                ;;
        esac

        echo
        read -r -p "按回车继续……" _
    done
}

# ---------------------------------------------------------------------------
# 主入口
# ---------------------------------------------------------------------------

require_root
ensure_dirs

case "${1:-}" in
    --daemon)
        daemon_loop
        ;;
    --check-all)
        check_all_once
        ;;
    --version)
        echo "$VERSION"
        ;;
    "")
        menu
        ;;
    *)
        echo "用法：$0 [--daemon|--check-all|--version]"
        exit 1
        ;;
esac
