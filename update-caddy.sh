#!/bin/bash
# =============================================================================
# update-caddy.sh — Download latest Caddy with coraza-caddy module, replace binary
# Safe: validates new binary before replacing, restarts only on success.
# Run as: root, or via monthly cron.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for candidate in "/usr/local/lib/serverdeploy" "${SCRIPT_DIR}/lib"; do
    [[ -f "${candidate}/common.sh" ]] && { source "${candidate}/common.sh"; break; }
done

require_root
load_config

CADDY_BIN=/usr/local/bin/caddy
DL_URL="https://caddyserver.com/api/download?os=linux&arch=amd64&p=github.com%2Fcorazawaf%2Fcoraza-caddy%2Fv2"

OLD_VERSION=$("${CADDY_BIN}" version 2>/dev/null | head -1 || echo "unknown")
info "Current Caddy: ${OLD_VERSION}"

info "Downloading latest Caddy with coraza-caddy..."
TMP_BIN=$(mktemp)
if ! curl -fsSL --retry 3 -o "${TMP_BIN}" "${DL_URL}"; then
    rm -f "${TMP_BIN}"
    die "Download failed."
fi
chmod +x "${TMP_BIN}"

NEW_VERSION=$("${TMP_BIN}" version 2>/dev/null | head -1 || echo "unknown")
info "Downloaded Caddy: ${NEW_VERSION}"

if [[ "${OLD_VERSION}" == "${NEW_VERSION}" ]]; then
    info "Already up to date. Nothing to do."
    rm -f "${TMP_BIN}"
    exit 0
fi

# Validate the new binary can parse the existing Caddyfile
if ! "${TMP_BIN}" validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
    rm -f "${TMP_BIN}"
    die "New binary fails to validate existing Caddyfile — not replacing."
fi
success "New binary validates existing config."

# Replace and restart
mv "${TMP_BIN}" "${CADDY_BIN}"
chmod 755 "${CADDY_BIN}"
systemctl restart caddy
sleep 2
if systemctl is-active --quiet caddy; then
    success "Caddy updated: ${OLD_VERSION} → ${NEW_VERSION}"
    # Notify admin
    source /usr/local/lib/serverdeploy/notify.sh 2>/dev/null && \
        send_email "Caddy updated to ${NEW_VERSION}" \
            "Caddy on $(hostname -f) updated from ${OLD_VERSION} to ${NEW_VERSION} at $(date)." 2>/dev/null || true
else
    die "Caddy failed to start after update. Rollback: restore binary from backup."
fi
