#!/bin/bash
# =============================================================================
# notify.sh — alert dispatcher
#
# Subject format: "[Alert on <hostname>] <topic>"
# Transport: whatever sendmail symlink points to (msmtp / serverdeploy-mail).
# When SMTP_RELAY=none, falls through to syslog + /var/log/serverdeploy/alerts.log
# so the monitoring still leaves a trail.
#
# Usage:
#   source /usr/local/lib/serverdeploy/notify.sh
#   send_email "RAM 92%" "details..."
#   send_email_file "backup failed" /path/to/body.txt
#   send_alert <key> <cooldown_seconds> "subject" "body"   # cooldown-aware
# =============================================================================

if [[ -n "${_NOTIFY_SH_LOADED:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi
_NOTIFY_SH_LOADED=1

_NOTIFY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for _candidate in \
    "${_NOTIFY_DIR}/common.sh" \
    "/usr/local/lib/serverdeploy/common.sh"; do
    if [[ -f "${_candidate}" ]]; then
        # shellcheck disable=SC1090
        source "${_candidate}"
        break
    fi
done

_NOTIFY_LOG=/var/log/serverdeploy/alerts.log

_log_alert() {
    local subject="$1" body="$2"
    mkdir -p "$(dirname "${_NOTIFY_LOG}")"
    {
        echo "[$(date -Iseconds)] ${subject}"
        echo "${body}"
        echo "---"
    } >> "${_NOTIFY_LOG}"
    logger -t serverdeploy-alert "${subject}"
}

send_email() {
    local subject="$1" body="$2"
    load_config
    local to="${ADMIN_EMAIL:-root}"
    local from_name="${MAIL_FROM_NAME:-serverdeploy}"
    local from_addr="${MAIL_FROM_ADDR:-root@$(hostname -f 2>/dev/null || hostname)}"
    local host
    host="$(hostname -s)"
    local full_subject="[Alert on ${host}] ${subject}"

    # Always log
    _log_alert "${full_subject}" "${body}"

    # No relay → stop after logging
    if [[ "${SMTP_RELAY:-none}" == "none" ]]; then
        return 0
    fi

    {
        echo "From: ${from_name} <${from_addr}>"
        echo "To: ${to}"
        echo "Subject: ${full_subject}"
        echo "Content-Type: text/plain; charset=UTF-8"
        echo
        echo "${body}"
    } | sendmail -t 2>/dev/null || return 1
}

send_email_file() {
    local subject="$1" body_file="$2"
    [[ -f "${body_file}" ]] || return 1
    send_email "${subject}" "$(cat "${body_file}")"
}

# Cooldown-aware: only fires if cooldown_should_fire returns 0 for <key>.
send_alert() {
    local key="$1" cooldown="$2" subject="$3" body="$4"
    if cooldown_should_fire "${key}" "${cooldown}"; then
        send_email "${subject}" "${body}"
    fi
}

# Recovery notice: clears the cooldown and sends a one-shot "RECOVERED".
send_recovery() {
    local key="$1" subject="$2" body="${3:-}"
    local f="/var/lib/serverdeploy/alerts/${key//\//_}.state"
    [[ -f "${f}" ]] || return 0   # was never alerting → nothing to recover
    cooldown_clear "${key}"
    send_email "RECOVERED: ${subject}" "${body:-Condition cleared at $(date -Iseconds).}"
}
