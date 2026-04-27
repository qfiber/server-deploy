#!/bin/bash
# =============================================================================
# adminip.sh — manage the IP allowlist for admin endpoints
#               (mail.<host>, pma.<host>, pga.<host>)
#
# Source of truth: MAIL_ADMIN_ALLOWLIST in /etc/serverdeploy/config (CSV).
# Every Caddy snippet that uses the allowlist reads this single key, so all
# endpoints update atomically when this script rewrites the value.
#
# Usage:
#   adminip allow-all
#   adminip allow  <ip|cidr>
#   adminip remove                # numbered list, pick by number
#   adminip remove <ip|cidr>      # exact match; on no match → numbered prompt
#   adminip list
#
# Validates with `caddy validate` before reload; rolls back the config on fail.
# Audit log at /var/log/serverdeploy/adminip.log.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for candidate in "/usr/local/lib/serverdeploy" "${SCRIPT_DIR}/lib"; do
    [[ -f "${candidate}/common.sh" ]] && { source "${candidate}/common.sh"; break; }
done
type require_root >/dev/null 2>&1 || { echo "[ERROR] common.sh not found"; exit 1; }
require_root

CONFIG=/etc/serverdeploy/config
CADDY=/usr/local/bin/caddy
CADDYFILE=/etc/caddy/Caddyfile
LOG=/var/log/serverdeploy/adminip.log
mkdir -p "$(dirname "${LOG}")"

[[ -f "${CONFIG}" ]] || die "Config not found at ${CONFIG}"

audit() {
    local action="$1" before="$2" after="$3"
    {
        echo "[$(date -Iseconds)] actor=${SUDO_USER:-${USER}} action=${action}"
        echo "  before: ${before}"
        echo "  after : ${after}"
    } >> "${LOG}"
}

current_list() {
    load_config
    echo "${MAIL_ADMIN_ALLOWLIST:-}"
}

apply_list() {
    local new="$1" old="$2"
    # Backup config and rewrite
    cp "${CONFIG}" "${CONFIG}.bak.$$"
    config_set MAIL_ADMIN_ALLOWLIST "${new}"

    # Re-render every Caddy admin snippet that references this allowlist
    rewrite_caddy_snippets "${new}" "${old}"

    if "${CADDY}" validate --config "${CADDYFILE}" --adapter caddyfile >/dev/null 2>&1; then
        systemctl reload caddy && success "Caddy reloaded." || warn "Caddy reload failed."
        rm -f "${CONFIG}.bak.$$"
        audit "${ACTION}" "${old}" "${new}"
    else
        warn "Caddy validation failed — rolling back."
        mv "${CONFIG}.bak.$$" "${CONFIG}"
        rewrite_caddy_snippets "${old}" "${new}"
        die "Rolled back. Check: ${CADDY} validate --config ${CADDYFILE} --adapter caddyfile"
    fi
}

# Replace the @allowed remote_ip line in every admin Caddy snippet
rewrite_caddy_snippets() {
    local new="$1" old="$2"
    local f
    # Convert CSV → space-separated for Caddy
    local new_caddy="${new//,/ }"
    for f in /etc/caddy/sites/*.caddy; do
        [[ -f "${f}" ]] || continue
        # Only files that already use @allowed remote_ip (admin endpoints)
        grep -q '@allowed remote_ip' "${f}" || continue
        sed -i -E "s|@allowed remote_ip .*|@allowed remote_ip ${new_caddy}|" "${f}"
    done
}

list_with_numbers() {
    local list="$1"
    local i=1
    IFS=',' read -ra arr <<<"${list}"
    for e in "${arr[@]}"; do
        e="${e//[[:space:]]/}"
        [[ -z "${e}" ]] && continue
        printf '  %d) %s\n' "${i}" "${e}"
        i=$((i + 1))
    done
}

remove_at_index() {
    local list="$1" target_idx="$2"
    local i=1 out=""
    IFS=',' read -ra arr <<<"${list}"
    for e in "${arr[@]}"; do
        e="${e//[[:space:]]/}"
        [[ -z "${e}" ]] && continue
        if [[ ${i} -ne ${target_idx} ]]; then
            out="${out:+${out},}${e}"
        fi
        i=$((i + 1))
    done
    echo "${out}"
}

remove_value() {
    local list="$1" target="$2"
    local out=""
    IFS=',' read -ra arr <<<"${list}"
    for e in "${arr[@]}"; do
        e="${e//[[:space:]]/}"
        [[ -z "${e}" ]] && continue
        if [[ "${e}" != "${target}" ]]; then
            out="${out:+${out},}${e}"
        fi
    done
    echo "${out}"
}

# -----------------------------------------------------------------------------
# Subcommands
# -----------------------------------------------------------------------------
ACTION="${1:-}"
ARG="${2:-}"

case "${ACTION}" in
    list)
        cur=$(current_list)
        if [[ -z "${cur}" ]]; then
            info "Allowlist is empty (admin endpoints will reject all)."
            exit 0
        fi
        echo
        info "Admin allowlist (mail/pma/pga):"
        list_with_numbers "${cur}"
        echo
        ;;

    allow-all)
        cur=$(current_list)
        echo
        warn "================================================================"
        warn "  This exposes phpMyAdmin, pgAdmin4, and the Stalwart admin"
        warn "  panel to the entire internet. WAF + basic auth + rate limit"
        warn "  remain, but IP allowlisting is your strongest layer."
        warn "================================================================"
        echo
        prompt CONFIRM "Type 'YES' to confirm"
        [[ "${CONFIRM}" == "YES" ]] || die "Aborted."
        apply_list "0.0.0.0/0,::/0" "${cur}"
        success "Allowlist set to 0.0.0.0/0,::/0"
        ;;

    allow)
        [[ -n "${ARG}" ]] || die "Usage: adminip allow <ip|cidr>"
        valid_ip_or_cidr "${ARG}" || die "Not a valid IP or CIDR: ${ARG}"
        cur=$(current_list)
        # Dedupe
        IFS=',' read -ra arr <<<"${cur}"
        for e in "${arr[@]}"; do
            e="${e//[[:space:]]/}"
            [[ "${e}" == "${ARG}" ]] && die "Already in allowlist: ${ARG}"
        done
        if [[ -z "${cur}" ]]; then
            new="${ARG}"
        else
            new="${cur},${ARG}"
        fi
        apply_list "${new}" "${cur}"
        success "Added ${ARG}."
        ;;

    remove)
        cur=$(current_list)
        [[ -n "${cur}" ]] || die "Allowlist is empty."

        if [[ -n "${ARG}" ]]; then
            # Try exact match
            IFS=',' read -ra arr <<<"${cur}"
            matched=0
            for e in "${arr[@]}"; do
                e="${e//[[:space:]]/}"
                [[ "${e}" == "${ARG}" ]] && matched=1
            done
            if [[ ${matched} -eq 1 ]]; then
                new=$(remove_value "${cur}" "${ARG}")
                apply_list "${new}" "${cur}"
                success "Removed ${ARG}."
                exit 0
            fi
            warn "No exact match for '${ARG}'. Current allowlist:"
        else
            info "Current allowlist:"
        fi

        list_with_numbers "${cur}"
        echo
        prompt PICK "Number to remove (blank to abort)"
        [[ -z "${PICK}" ]] && { info "Aborted."; exit 0; }
        [[ "${PICK}" =~ ^[0-9]+$ ]] || die "Not a number."
        # Bound check
        IFS=',' read -ra arr <<<"${cur}"
        cnt=0
        for e in "${arr[@]}"; do
            [[ -z "${e//[[:space:]]/}" ]] && continue
            cnt=$((cnt + 1))
        done
        (( PICK >= 1 && PICK <= cnt )) || die "Out of range."
        new=$(remove_at_index "${cur}" "${PICK}")
        apply_list "${new}" "${cur}"
        success "Removed entry #${PICK}."
        ;;

    *)
        cat <<USAGE
Usage:
  adminip allow-all                opens admin endpoints (with confirmation)
  adminip allow  <ip|cidr>         adds an entry
  adminip remove                   numbered list, pick number
  adminip remove <ip|cidr>         exact match; falls back to numbered list
  adminip list                     show current allowlist
USAGE
        exit 1
        ;;
esac
