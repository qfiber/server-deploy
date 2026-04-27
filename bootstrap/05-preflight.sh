#!/bin/bash
# =============================================================================
# 05-preflight.sh — pre-install sanity checks
#   - public IP detection (NAT-aware)
#   - DNS A-record check for SERVER_HOSTNAME / MAIL_ADMIN_HOST / pma / pga
#   - DB bind audit (refuses to continue if mariadb/postgres on 0.0.0.0 — only
#     applies on re-runs after 20-databases has installed them)
#   - umask check (0077 expected for install session)
#   - secret-file mode check on re-runs
#
# Honors SKIP_DNS_CHECK=1 (env or flag) to bypass DNS validation only.
# Hard-fails on syntactically invalid config; warns + prompts on DNS mismatch.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${REPO_DIR}/lib/common.sh"

require_root

# -----------------------------------------------------------------------------
# 0. umask
# -----------------------------------------------------------------------------
cur_umask=$(umask)
if [[ "${cur_umask}" != "0077" ]]; then
    info "Tightening umask for the install session (was ${cur_umask})..."
    umask 0077
fi

# -----------------------------------------------------------------------------
# 1. Re-run secret-file audit
# -----------------------------------------------------------------------------
if [[ -d /etc/serverdeploy ]]; then
    bad=()
    while IFS= read -r f; do
        mode=$(stat -c '%a' "${f}" 2>/dev/null)
        if [[ -n "${mode}" && ${mode} -gt 600 ]]; then
            bad+=("${f} (mode ${mode})")
        fi
    done < <(find /etc/serverdeploy -maxdepth 2 -type f \
        \( -name 'config' -o -name '*.password' -o -name '*-admin.txt' -o -name '*.txt' \) 2>/dev/null)
    if (( ${#bad[@]} > 0 )); then
        warn "Sensitive files with overly permissive modes detected:"
        for b in "${bad[@]}"; do warn "  ${b}"; done
        warn "Tightening to 600..."
        for f in /etc/serverdeploy/config /etc/serverdeploy/*.password /etc/serverdeploy/*-admin.txt; do
            [[ -f "${f}" ]] && chmod 600 "${f}"
        done
    fi
fi

# -----------------------------------------------------------------------------
# 2. Public IP detection
# -----------------------------------------------------------------------------
info "Detecting public IP..."
detected="$(detect_public_ip || true)"
PUBLIC_IP=""
PUBLIC_SRC=""
if [[ -n "${detected}" ]]; then
    PUBLIC_IP="${detected%	*}"
    PUBLIC_SRC="${detected#*	}"
    success "Public IP: ${PUBLIC_IP}  (via ${PUBLIC_SRC})"
else
    warn "Could not detect public IP — DNS validation will be skipped."
fi

# NAT awareness: detected public IP not present on any local interface
if [[ -n "${PUBLIC_IP}" ]]; then
    if ! ip -4 addr show 2>/dev/null | grep -qE "inet ${PUBLIC_IP}\b"; then
        warn "Server appears to be behind NAT/load balancer."
        warn "  detected public IP : ${PUBLIC_IP}"
        warn "  local IPs          : $(hostname -I | tr ' ' ',' | sed 's/,$//')"
        warn "  Make sure your firewall/NAT forwards the following ports to this host:"
        warn "    80/tcp, 443/tcp, 443/udp, 25/tcp, 465/tcp, 587/tcp, 993/tcp, ${SSH_PORT:-2223}/tcp"
    fi
fi

# -----------------------------------------------------------------------------
# 3. DNS validation
# -----------------------------------------------------------------------------
SKIP_DNS="${SKIP_DNS_CHECK:-0}"
[[ "${1:-}" == "--skip-dns" ]] && SKIP_DNS=1

# Pull from config if present, else from environment, else from hostname -f
load_config 2>/dev/null || true
CHECK_HOSTS=()
[[ -n "${SERVER_HOSTNAME:-}" ]]   && CHECK_HOSTS+=("server hostname|${SERVER_HOSTNAME}")
[[ -n "${MAIL_ADMIN_HOST:-}" ]]   && CHECK_HOSTS+=("mail admin|${MAIL_ADMIN_HOST}")
[[ -n "${PMA_HOST:-}" ]]          && CHECK_HOSTS+=("phpMyAdmin|${PMA_HOST}")
[[ -n "${PGA_HOST:-}" ]]          && CHECK_HOSTS+=("pgAdmin4|${PGA_HOST}")

if [[ ${#CHECK_HOSTS[@]} -eq 0 ]]; then
    info "No hostnames configured yet — DNS check skipped (00-base will prompt)."
elif [[ "${SKIP_DNS}" == "1" ]]; then
    warn "DNS validation skipped (--skip-dns / SKIP_DNS_CHECK=1)."
elif [[ -z "${PUBLIC_IP}" ]]; then
    warn "DNS validation skipped — could not detect public IP."
else
    info "Validating DNS A records against ${PUBLIC_IP} ..."
    mismatch=0
    for entry in "${CHECK_HOSTS[@]}"; do
        label="${entry%%|*}"
        host="${entry##*|}"
        valid_domain "${host}" || die "Invalid FQDN for ${label}: ${host}"
        a=$(resolve_a "${host}")
        if [[ -z "${a}" ]]; then
            printf '  %-15s %-40s %s\n' "${label}" "${host}" "NXDOMAIN ✗"
            mismatch=1
        elif [[ "${a}" == "${PUBLIC_IP}" ]]; then
            printf '  %-15s %-40s %s\n' "${label}" "${host}" "${a} ✓"
        else
            printf '  %-15s %-40s %s\n' "${label}" "${host}" "${a} ✗ (mismatch)"
            mismatch=1
        fi
    done
    if [[ ${mismatch} -eq 1 ]]; then
        echo
        warn "One or more hostnames don't resolve to ${PUBLIC_IP}."
        warn "DNS often propagates after install starts; Caddy will retry cert issuance."
        prompt CONTINUE_ANYWAY "Continue anyway? (y/N)" "n"
        [[ "${CONTINUE_ANYWAY,,}" =~ ^y ]] || die "Aborted by user (DNS mismatch)."
    else
        success "All configured hostnames resolve to ${PUBLIC_IP}."
    fi
fi

# -----------------------------------------------------------------------------
# 4. Database bind audit (re-runs only — DBs not installed on first pass)
# -----------------------------------------------------------------------------
audit_bind() {
    local svc="$1" port="$2"
    if systemctl is-active --quiet "${svc}" 2>/dev/null; then
        local listen
        listen=$(ss -tlnH 2>/dev/null | awk -v p=":${port}" '$4 ~ p {print $4}' | head -1)
        if [[ -n "${listen}" && "${listen}" != "127.0.0.1:${port}" && "${listen}" != "[::1]:${port}" ]]; then
            die "${svc} is bound to ${listen}, expected 127.0.0.1:${port}. Refusing to continue."
        fi
    fi
}
audit_bind mariadb 3306
audit_bind postgresql-16 5432
audit_bind postgresql 5432

# -----------------------------------------------------------------------------
# Done
# -----------------------------------------------------------------------------
echo
success "05-preflight.sh complete."
