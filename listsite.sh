#!/bin/bash
# =============================================================================
# listsite.sh — List all provisioned sites and their status
# Run as: root
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for candidate in "/usr/local/lib/serverdeploy" "${SCRIPT_DIR}/lib"; do
    [[ -f "${candidate}/common.sh" ]] && { source "${candidate}/common.sh"; break; }
done

require_root

SITES_META_DIR="/etc/serverdeploy/sites"
mapfile -t METAS < <(ls -1 "${SITES_META_DIR}"/*.meta 2>/dev/null | sort)

if [[ ${#METAS[@]} -eq 0 ]]; then
    info "No provisioned sites."
    exit 0
fi

printf '\n'
printf '%-30s %-6s %-12s %-8s %-18s %s\n' "DOMAIN" "TYPE" "PORTS" "DB" "SERVICE STATUS" "CREATED"
printf '%-30s %-6s %-12s %-8s %-18s %s\n' "------" "----" "-----" "--" "--------------" "-------"

for meta in "${METAS[@]}"; do
    # Reset defaults
    DOMAIN="" SITE_TYPE="" APP_PORT="" API_PORT="" UI_PORT=""
    DB_TYPE="none" SYSTEMD_UNITS="" POOL_CONF="" CREATED_AT=""

    # shellcheck disable=SC1090
    source "${meta}"

    # Ports
    if [[ -n "${APP_PORT}" ]]; then
        ports="${APP_PORT}"
    elif [[ -n "${API_PORT}" ]]; then
        ports="${API_PORT},${UI_PORT}"
    else
        ports="-"
    fi

    # DB
    db="${DB_TYPE:-none}"
    [[ "${db}" == "none" ]] && db="-"

    # Service status
    status=""
    if [[ "${SITE_TYPE}" == "node" && -n "${SYSTEMD_UNITS}" ]]; then
        IFS=',' read -ra units <<< "${SYSTEMD_UNITS}"
        all_active=true
        for u in "${units[@]}"; do
            if systemctl is-active --quiet "${u}.service" 2>/dev/null; then
                :
            else
                all_active=false
                break
            fi
        done
        ${all_active} && status="running" || status="stopped"
    elif [[ "${SITE_TYPE}" == "php" ]]; then
        if [[ -n "${POOL_CONF}" && -f "${POOL_CONF}" ]] && systemctl is-active --quiet php-fpm 2>/dev/null; then
            status="running"
        else
            status="stopped"
        fi
    else
        status="unknown"
    fi

    # Created date (trim time)
    created="${CREATED_AT:0:10}"

    printf '%-30s %-6s %-12s %-8s %-18s %s\n' \
        "${DOMAIN}" "${SITE_TYPE:-?}" "${ports}" "${db}" "${status}" "${created}"
done
printf '\n'
