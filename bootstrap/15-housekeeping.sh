#!/bin/bash
# =============================================================================
# 15-housekeeping.sh — logrotate + quarterly CRS refresh + delsite archive sweep
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${REPO_DIR}/lib/common.sh"

require_root

# -----------------------------------------------------------------------------
# 1. logrotate for per-site PHP + app logs
# -----------------------------------------------------------------------------
info "Installing logrotate config for /srv/sites..."
cat > /etc/logrotate.d/serverdeploy-sites <<'EOF'
/srv/sites/*/logs/*.log /srv/sites/*/logs/*.err {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    su root root
}

/var/log/serverdeploy/*.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}

/var/log/caddy/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    sharedscripts
    su caddy caddy
    postrotate
        systemctl reload caddy >/dev/null 2>&1 || true
    endscript
}

/var/log/phpMyAdmin/*.log /var/log/pgadmin/*.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
chmod 644 /etc/logrotate.d/serverdeploy-sites
success "logrotate config written."

# -----------------------------------------------------------------------------
# 2. Quarterly OWASP CRS refresh
# -----------------------------------------------------------------------------
info "Installing CRS quarterly refresh script..."
cat > /usr/local/bin/serverdeploy-crs-refresh <<'CRS'
#!/bin/bash
# Refresh OWASP CRS to the latest tagged release. Runs quarterly.
set -euo pipefail
CRS_DIR=/etc/caddy/coraza/crs
TMP=$(mktemp -d)
trap 'rm -rf "${TMP}"' EXIT
LATEST=$(curl -fsSL https://api.github.com/repos/coreruleset/coreruleset/releases/latest | jq -r .tag_name)
[[ "${LATEST}" =~ ^v ]] || { echo "Could not get CRS latest tag" >&2; exit 1; }
CURRENT=$(awk -F'"' '/SecComponentSignature/ {print $2}' "${CRS_DIR}/crs-setup.conf" 2>/dev/null || echo "")
echo "current: ${CURRENT}  latest: ${LATEST}"
curl -fsSL "https://github.com/coreruleset/coreruleset/archive/refs/tags/${LATEST}.tar.gz" \
    | tar -xz -C "${TMP}" --strip-components=1
# Preserve crs-setup.conf (operator may have tuned it) by NOT overwriting it
[[ -f "${CRS_DIR}/crs-setup.conf" ]] && cp "${CRS_DIR}/crs-setup.conf" "${TMP}/crs-setup.conf.preserve"
rsync -a --exclude='crs-setup.conf' "${TMP}/" "${CRS_DIR}/"
chown -R root:caddy "${CRS_DIR}"
find "${CRS_DIR}" -type d -exec chmod 750 {} +
find "${CRS_DIR}" -type f -exec chmod 640 {} +
if /usr/local/bin/caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
    systemctl reload caddy && echo "Caddy reloaded after CRS update." || true
else
    echo "CRS refresh: Caddyfile failed validation. Investigate." >&2
    exit 1
fi
echo "CRS updated to ${LATEST}."
CRS
chmod 755 /usr/local/bin/serverdeploy-crs-refresh

# Run on the 1st of Jan / Apr / Jul / Oct at 04:00
cat > /etc/cron.d/serverdeploy-crs-refresh <<'EOF'
0 4 1 1,4,7,10 * root /usr/local/bin/serverdeploy-crs-refresh >> /var/log/serverdeploy/crs-refresh.log 2>&1
EOF
chmod 644 /etc/cron.d/serverdeploy-crs-refresh
success "CRS quarterly refresh installed."

# -----------------------------------------------------------------------------
# 3. delsite archive sweep (older than 7 days)
# -----------------------------------------------------------------------------
cat > /etc/cron.d/serverdeploy-archive-sweep <<'EOF'
# Delete delsite archives older than 7 days
30 2 * * * root find /srv/backups/archived -type f -name '*.tar.gz' -mtime +7 -delete 2>/dev/null
EOF
chmod 644 /etc/cron.d/serverdeploy-archive-sweep
success "Archive sweep cron installed."

echo
success "15-housekeeping.sh complete."
