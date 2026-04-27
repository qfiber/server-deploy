#!/bin/bash
# =============================================================================
# waf-whitelist.sh — manage Coraza/CRS rule exclusions
# Run as: root
#
# Menu:
#   1) Disable rule for one site
#   2) Disable rule globally (server)
#   3) Bypass WAF for one IP (all sites)
#   4) Disable rule for one path
#
# Per-site rules → /etc/caddy/coraza/sites/<domain>.conf
# Global rules   → /etc/caddy/coraza/whitelist.conf
# Auto-allocates rule IDs from /etc/caddy/coraza/.next-id (starts at 2000)
# Validates with `caddy validate` before reload; rolls back on failure.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for candidate in "/usr/local/lib/serverdeploy" "${SCRIPT_DIR}/lib"; do
    [[ -f "${candidate}/common.sh" ]] && { source "${candidate}/common.sh"; break; }
done
type require_root >/dev/null 2>&1 || { echo "[ERROR] common.sh not found"; exit 1; }
require_root

CADDY=/usr/local/bin/caddy
CADDYFILE=/etc/caddy/Caddyfile
CORAZA_DIR=/etc/caddy/coraza
SITES_CORAZA="${CORAZA_DIR}/sites"
GLOBAL_FILE="${CORAZA_DIR}/whitelist.conf"
ID_FILE="${CORAZA_DIR}/.next-id"
SITES_META=/etc/serverdeploy/sites

mkdir -p "${SITES_CORAZA}"
[[ -f "${ID_FILE}" ]] || echo 2000 > "${ID_FILE}"

next_id() {
    local id
    id=$(<"${ID_FILE}")
    echo $((id + 1)) > "${ID_FILE}"
    chmod 640 "${ID_FILE}"
    chown root:caddy "${ID_FILE}" 2>/dev/null || true
    echo "${id}"
}

reload_caddy_or_rollback() {
    local file="$1" backup="$2"
    if "${CADDY}" validate --config "${CADDYFILE}" --adapter caddyfile >/dev/null 2>&1; then
        systemctl reload caddy && success "Caddy reloaded." || warn "Caddy reload failed."
    else
        warn "Caddy validation FAILED — rolling back."
        if [[ -n "${backup}" && -f "${backup}" ]]; then
            mv "${backup}" "${file}"
        else
            rm -f "${file}"
        fi
        die "Rolled back. Inspect with: ${CADDY} validate --config ${CADDYFILE} --adapter caddyfile"
    fi
}

pick_site() {
    mapfile -t SITES < <(ls -1 "${SITES_META}"/*.meta 2>/dev/null | sed 's|.*/||; s|\.meta$||' | sort)
    [[ ${#SITES[@]} -gt 0 ]] || die "No sites found."
    echo
    info "Sites:"
    for i in "${!SITES[@]}"; do
        printf '  %d) %s\n' "$((i + 1))" "${SITES[$i]}"
    done
    echo
    prompt PICK "Number"
    [[ "${PICK}" =~ ^[0-9]+$ ]] || die "Not a number."
    local idx=$((PICK - 1))
    [[ ${idx} -ge 0 && ${idx} -lt ${#SITES[@]} ]] || die "Out of range."
    SELECTED_SITE="${SITES[$idx]}"
}

# -----------------------------------------------------------------------------
# Menu
# -----------------------------------------------------------------------------
echo
info "=== WAF whitelist ==="
echo "  1) Disable a rule for one site"
echo "  2) Disable a rule globally (server)"
echo "  3) Bypass WAF for one IP (all sites)"
echo "  4) Disable a rule for a specific path (all sites)"
echo
prompt CHOICE "Choice [1-4]"

case "${CHOICE}" in
    1)
        pick_site
        prompt RULE_ID "CRS rule ID to disable (e.g. 942100)"
        [[ "${RULE_ID}" =~ ^[0-9]+$ ]] || die "Rule ID must be numeric."
        FILE="${SITES_CORAZA}/${SELECTED_SITE}.conf"
        BACKUP=""
        [[ -f "${FILE}" ]] && { BACKUP="${FILE}.bak.$$"; cp "${FILE}" "${BACKUP}"; }
        ID=$(next_id)
        # Match by Host header so the rule applies only to that vhost
        cat >> "${FILE}" <<RULE
# $(date -Iseconds): disable rule ${RULE_ID} for ${SELECTED_SITE}
SecRule REQUEST_HEADERS:Host "@streq ${SELECTED_SITE}" \\
    "id:${ID},phase:1,pass,nolog,ctl:ruleRemoveById=${RULE_ID}"
RULE
        chown root:caddy "${FILE}"
        chmod 640 "${FILE}"
        success "Wrote rule ${ID} → ${FILE}"
        reload_caddy_or_rollback "${FILE}" "${BACKUP}"
        [[ -n "${BACKUP}" && -f "${BACKUP}" ]] && rm -f "${BACKUP}"
        ;;
    2)
        prompt RULE_ID "CRS rule ID to disable globally"
        [[ "${RULE_ID}" =~ ^[0-9]+$ ]] || die "Rule ID must be numeric."
        BACKUP="${GLOBAL_FILE}.bak.$$"
        cp "${GLOBAL_FILE}" "${BACKUP}"
        cat >> "${GLOBAL_FILE}" <<RULE
# $(date -Iseconds): disable rule ${RULE_ID} globally
SecRuleRemoveById ${RULE_ID}
RULE
        success "Appended global removal of ${RULE_ID}."
        reload_caddy_or_rollback "${GLOBAL_FILE}" "${BACKUP}"
        rm -f "${BACKUP}"
        ;;
    3)
        while :; do
            prompt IP "IP/CIDR to bypass (v4 or v6)"
            valid_ip_or_cidr "${IP}" && break
            warn "Invalid: ${IP}"
        done
        BACKUP="${GLOBAL_FILE}.bak.$$"
        cp "${GLOBAL_FILE}" "${BACKUP}"
        ID1=$(next_id); ID2=$(next_id)
        cat >> "${GLOBAL_FILE}" <<RULE
# $(date -Iseconds): bypass WAF for ${IP}
SecRule REMOTE_ADDR "@ipMatch ${IP}" \\
    "id:${ID1},phase:1,pass,nolog,ctl:ruleEngine=Off,msg:'WAF bypass — ${IP} (direct)'"
SecRule REQUEST_HEADERS:CF-Connecting-IP "@ipMatch ${IP}" \\
    "id:${ID2},phase:1,pass,nolog,ctl:ruleEngine=Off,msg:'WAF bypass — ${IP} (CF)'"
RULE
        success "WAF bypass appended for ${IP}."
        reload_caddy_or_rollback "${GLOBAL_FILE}" "${BACKUP}"
        rm -f "${BACKUP}"
        ;;
    4)
        prompt RULE_ID "CRS rule ID to disable on a path"
        [[ "${RULE_ID}" =~ ^[0-9]+$ ]] || die "Rule ID must be numeric."
        prompt PATH_PFX "Path prefix (e.g. /wp-admin/admin-ajax.php)"
        [[ "${PATH_PFX}" =~ ^/ ]] || die "Path must start with /"
        BACKUP="${GLOBAL_FILE}.bak.$$"
        cp "${GLOBAL_FILE}" "${BACKUP}"
        ID=$(next_id)
        cat >> "${GLOBAL_FILE}" <<RULE
# $(date -Iseconds): disable rule ${RULE_ID} on path ${PATH_PFX}
SecRule REQUEST_URI "@beginsWith ${PATH_PFX}" \\
    "id:${ID},phase:1,pass,nolog,ctl:ruleRemoveById=${RULE_ID}"
RULE
        success "Path-scoped removal appended."
        reload_caddy_or_rollback "${GLOBAL_FILE}" "${BACKUP}"
        rm -f "${BACKUP}"
        ;;
    *)
        die "Pick 1-4."
        ;;
esac

echo
success "Done."
