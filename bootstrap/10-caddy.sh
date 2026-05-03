#!/bin/bash
# =============================================================================
# 10-caddy.sh — Caddy + Coraza WAF + base config
#   - downloads Caddy with coraza-caddy v2 module + caddy-ratelimit baked in
#   - downloads OWASP CRS rules
#   - writes base Caddyfile (server hostname + waf snippet + secure_headers + catchall)
#   - per-site coraza include dir at /etc/caddy/coraza/sites/
#   - cert export for Stalwart
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${REPO_DIR}/lib/common.sh"

require_root
load_config

[[ -n "${ADMIN_EMAIL:-}" ]]    || die "ADMIN_EMAIL not set in /etc/serverdeploy/config — run 00-base.sh first."
[[ -n "${SERVER_HOSTNAME:-}" ]] || die "SERVER_HOSTNAME not set in /etc/serverdeploy/config — run 00-base.sh first."

CADDY_BIN=/usr/local/bin/caddy
CADDY_USER=caddy
CADDY_GROUP=caddy
CADDY_HOME=/var/lib/caddy
CADDY_CONF=/etc/caddy
CADDY_LOG=/var/log/caddy
CRS_DIR=/etc/caddy/coraza/crs
CRS_VERSION="${CRS_VERSION:-v4.25.0}"

# -----------------------------------------------------------------------------
# 1. Caddy with coraza-caddy + caddy-ratelimit
# -----------------------------------------------------------------------------
info "Fetching Caddy with coraza-caddy + ratelimit modules..."
DL_URL="https://caddyserver.com/api/download?os=linux&arch=amd64&p=github.com%2Fcorazawaf%2Fcoraza-caddy%2Fv2&p=github.com%2Fmholt%2Fcaddy-ratelimit&p=github.com%2Fporech%2Fcaddy-maxmind-geolocation"
TMP_BIN="$(mktemp)"
curl -fsSL --retry 3 -o "${TMP_BIN}" "${DL_URL}" || die "Failed to download Caddy."
chmod +x "${TMP_BIN}"
"${TMP_BIN}" version >/dev/null 2>&1 || die "Downloaded Caddy is not executable."
install -m 0755 -o root -g root "${TMP_BIN}" "${CADDY_BIN}"
rm -f "${TMP_BIN}"
# mktemp lands the binary under tmp_t — without restoring context, systemd
# refuses to exec it ("Permission denied", status=203/EXEC).
if command -v restorecon >/dev/null 2>&1; then
    restorecon -v "${CADDY_BIN}" >/dev/null 2>&1 || true
fi
success "Caddy installed → ${CADDY_BIN} ($("${CADDY_BIN}" version | head -1))"

# -----------------------------------------------------------------------------
# 2. caddy user + dirs
# -----------------------------------------------------------------------------
info "Creating caddy user and directories..."
getent group "${CADDY_GROUP}" >/dev/null || groupadd --system "${CADDY_GROUP}"
getent passwd "${CADDY_USER}" >/dev/null || useradd \
    --system --gid "${CADDY_GROUP}" \
    --home-dir "${CADDY_HOME}" --create-home \
    --shell /usr/sbin/nologin \
    --comment "Caddy web server" "${CADDY_USER}"

mkdir -p "${CADDY_CONF}/sites" "${CADDY_CONF}/coraza" "${CADDY_CONF}/coraza/sites" \
         "${CADDY_CONF}/snippets" \
         "${CRS_DIR}" "${CADDY_LOG}" "${CADDY_HOME}"
chown -R "${CADDY_USER}:${CADDY_GROUP}" "${CADDY_HOME}" "${CADDY_LOG}"
chmod 755 "${CADDY_LOG}"
if command -v semanage >/dev/null 2>&1 && getenforce 2>/dev/null | grep -qE 'Enforcing|Permissive'; then
    semanage fcontext -a -t var_log_t "${CADDY_LOG}(/.*)?" 2>/dev/null || \
        semanage fcontext -m -t var_log_t "${CADDY_LOG}(/.*)?" 2>/dev/null || true
    semanage fcontext -a -t var_lib_t "${CADDY_HOME}(/.*)?" 2>/dev/null || \
        semanage fcontext -m -t var_lib_t "${CADDY_HOME}(/.*)?" 2>/dev/null || true
    restorecon -R "${CADDY_LOG}" "${CADDY_HOME}" 2>/dev/null || true
fi
chown -R root:"${CADDY_GROUP}" "${CADDY_CONF}"
chmod 750 "${CADDY_CONF}"
chmod g+rx "${CADDY_CONF}/sites"
chmod g+rx "${CADDY_CONF}/coraza/sites"
success "Caddy directories created."

# Initialize the rule-ID counter used by waf-whitelist.sh
ID_FILE="${CADDY_CONF}/coraza/.next-id"
[[ -f "${ID_FILE}" ]] || echo 2000 > "${ID_FILE}"
chmod 640 "${ID_FILE}"
chown root:"${CADDY_GROUP}" "${ID_FILE}"

# -----------------------------------------------------------------------------
# 3. OWASP CRS
# -----------------------------------------------------------------------------
if [[ ! -d "${CRS_DIR}/rules" ]]; then
    info "Downloading OWASP CRS ${CRS_VERSION}..."
    TMP_CRS="$(mktemp -d)"
    curl -fsSL "https://github.com/coreruleset/coreruleset/archive/refs/tags/${CRS_VERSION}.tar.gz" \
        | tar -xz -C "${TMP_CRS}" --strip-components=1
    rsync -a "${TMP_CRS}/" "${CRS_DIR}/"
    rm -rf "${TMP_CRS}"
    success "OWASP CRS ${CRS_VERSION} installed."
else
    info "OWASP CRS already present."
fi

[[ -f "${CRS_DIR}/crs-setup.conf" ]] || \
    cp "${CRS_DIR}/crs-setup.conf.example" "${CRS_DIR}/crs-setup.conf"

chown -R root:"${CADDY_GROUP}" "${CADDY_CONF}/coraza"
find "${CADDY_CONF}/coraza" -type d -exec chmod 750 {} +
find "${CADDY_CONF}/coraza" -type f -exec chmod 640 {} +

# -----------------------------------------------------------------------------
# 4. Coraza directives
# -----------------------------------------------------------------------------
info "Writing Coraza configuration..."
cat > "${CADDY_CONF}/coraza/coraza.conf" <<'EOF'
# Coraza recommended baseline directives
SecRuleEngine On
SecRequestBodyAccess On
SecRequestBodyLimit 13107200
SecRequestBodyNoFilesLimit 131072
SecRequestBodyLimitAction Reject
SecResponseBodyAccess On
SecResponseBodyMimeType text/plain text/html text/xml application/json
SecResponseBodyLimit 524288
SecResponseBodyLimitAction ProcessPartial
SecTmpDir /tmp/
SecDataDir /tmp/
SecAuditEngine RelevantOnly
SecAuditLogRelevantStatus "^(5|40[03])"
SecAuditLogParts ABIJDEFHZ
SecAuditLogType Serial
SecAuditLog /var/log/caddy/coraza-audit.log
SecArgumentSeparator &
SecCookieFormat 0
EOF
success "Coraza config written."

# Global allowlist
if [[ ! -f "${CADDY_CONF}/coraza/whitelist.conf" ]]; then
    cat > "${CADDY_CONF}/coraza/whitelist.conf" <<'EOF'
# =============================================================================
# /etc/caddy/coraza/whitelist.conf — server-wide WAF allowlist + rule exclusions
# Managed by waf-whitelist.sh (or hand-edit). Loaded BEFORE the CRS rules.
# After editing:  systemctl reload caddy
# =============================================================================
EOF
    success "Empty whitelist file created."
fi
chown root:"${CADDY_GROUP}" "${CADDY_CONF}/coraza/whitelist.conf"
chmod 640 "${CADDY_CONF}/coraza/whitelist.conf"

# -----------------------------------------------------------------------------
# 5. Caddyfile
# -----------------------------------------------------------------------------
info "Writing base Caddyfile..."
cat > "${CADDY_CONF}/Caddyfile" <<CADDYFILE
# =============================================================================
# Managed by serverdeploy 10-caddy.sh
# Per-site snippets imported from /etc/caddy/sites/*.caddy
# =============================================================================

{
	email ${ADMIN_EMAIL}
	order coraza_waf first
	order rate_limit before basic_auth
	servers {
		protocols h1 h2 h3
	}
	log default {
		output file /var/log/caddy/caddy.log {
			roll_size 50MB
			roll_keep 10
		}
	}
}

# -----------------------------------------------------------------------------
# WAF — sites do 'import waf'
# -----------------------------------------------------------------------------
(waf) {
	coraza_waf {
		directives \`
Include /etc/caddy/coraza/coraza.conf
Include /etc/caddy/coraza/crs/crs-setup.conf
Include /etc/caddy/coraza/whitelist.conf
Include /etc/caddy/coraza/sites/*.conf
Include /etc/caddy/coraza/crs/rules/*.conf
\`
	}
}

# -----------------------------------------------------------------------------
# Security headers — sites do 'import secure_headers'
# Per-site CSP overrides go in the site snippet AFTER the import.
# -----------------------------------------------------------------------------
(secure_headers) {
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "DENY"
		Referrer-Policy "strict-origin-when-cross-origin"
		Permissions-Policy "geolocation=(), microphone=(), camera=()"
		-Server
		-X-Powered-By
	}
}

# -----------------------------------------------------------------------------
# Admin endpoint guard — sites do 'import admin_guard <allowlist> <basic_user> <basic_hash>'
# -----------------------------------------------------------------------------
(admin_guard) {
	@allowed remote_ip {args[0]}
	rate_limit {
		zone admin_zone {
			key {client_ip}
			events 30
			window 1m
		}
	}
}

# -----------------------------------------------------------------------------
# Trusted CDN proxies — sites do 'import trusted_cdn'.
# Caddy then unwraps X-Forwarded-For from these networks so the country block
# (and rate limits, and logs) operate on the real client IP.
# Re-rendered by /usr/local/bin/serverdeploy-cdn-refresh (weekly cron).
# -----------------------------------------------------------------------------
import /etc/caddy/snippets/trusted_cdn.caddy

# -----------------------------------------------------------------------------
# GeoIP block — sites do 'import geoblock'.
# No-op if /var/lib/GeoIP/GeoLite2-Country.mmdb is missing (Caddy logs a warn).
# Re-rendered by geoblock.sh whenever the country list / bypass list changes.
# -----------------------------------------------------------------------------
import /etc/caddy/snippets/geoblock.caddy

# -----------------------------------------------------------------------------
# Server hostname — management identity, no public content
# -----------------------------------------------------------------------------
${SERVER_HOSTNAME} {
	abort
}

# -----------------------------------------------------------------------------
# Per-site snippets
# -----------------------------------------------------------------------------
import /etc/caddy/sites/*.caddy

# -----------------------------------------------------------------------------
# Catchall
# -----------------------------------------------------------------------------
:80 {
	abort
}

:443 {
	tls internal
	abort
}
CADDYFILE

chown root:"${CADDY_GROUP}" "${CADDY_CONF}/Caddyfile"
chmod 640 "${CADDY_CONF}/Caddyfile"
success "Caddyfile written."

# Snippet placeholders — required for the Caddyfile to validate even on a
# fresh install (the live versions get rendered later by 6b/6c and the
# weekly cdn-refresh / geoblock.sh).
mkdir -p "${CADDY_CONF}/snippets"
if [[ ! -f "${CADDY_CONF}/snippets/trusted_cdn.caddy" ]]; then
    cat > "${CADDY_CONF}/snippets/trusted_cdn.caddy" <<'TC'
(trusted_cdn) {
    servers {
        trusted_proxies static 127.0.0.1/32 ::1/128
    }
}
TC
fi
if [[ ! -f "${CADDY_CONF}/snippets/geoblock.caddy" ]]; then
    cat > "${CADDY_CONF}/snippets/geoblock.caddy" <<'GB'
(geoblock) {
    # GeoIP disabled or not yet configured. No-op snippet so 'import geoblock'
    # in site files keeps working until 45-geoip.sh runs and geoblock.sh
    # rewrites this file.
}
GB
fi
chown -R root:caddy "${CADDY_CONF}/snippets"
chmod 750 "${CADDY_CONF}/snippets"
chmod 640 "${CADDY_CONF}/snippets/"*.caddy

"${CADDY_BIN}" fmt --overwrite "${CADDY_CONF}/Caddyfile" 2>/dev/null || true
info "Validating Caddyfile..."
"${CADDY_BIN}" validate --config "${CADDY_CONF}/Caddyfile" --adapter caddyfile 2>&1 \
    || die "Caddyfile validation failed — review ${CADDY_CONF}/Caddyfile"
success "Caddyfile valid."

# -----------------------------------------------------------------------------
# 6. Cert export hook
# -----------------------------------------------------------------------------
info "Installing cert-export script..."
mkdir -p /etc/stalwart/certs
cat > /usr/local/bin/caddy-cert-export.sh <<'EXPORT'
#!/bin/bash
set -euo pipefail
SRC_BASE="/var/lib/caddy/.local/share/caddy/certificates"
DST_BASE="/etc/stalwart/certs"
mkdir -p "${DST_BASE}"
shopt -s nullglob
for ca_dir in "${SRC_BASE}"/*; do
    [[ -d "${ca_dir}" ]] || continue
    for cert_dir in "${ca_dir}"/*; do
        [[ -d "${cert_dir}" ]] || continue
        domain="$(basename "${cert_dir}")"
        crt="${cert_dir}/${domain}.crt"
        key="${cert_dir}/${domain}.key"
        [[ -f "${crt}" && -f "${key}" ]] || continue
        dst="${DST_BASE}/${domain}"
        mkdir -p "${dst}"
        install -m 0644 "${crt}" "${dst}/fullchain.pem"
        install -m 0640 "${key}" "${dst}/privkey.pem"
        if id stalwart >/dev/null 2>&1; then
            chown -R stalwart:stalwart "${dst}"
        fi
    done
done
if systemctl is-active --quiet stalwart 2>/dev/null; then
    systemctl reload stalwart 2>/dev/null || systemctl restart stalwart 2>/dev/null || true
fi
EXPORT
chmod 755 /usr/local/bin/caddy-cert-export.sh

cat > /etc/cron.d/caddy-cert-export <<'CRON'
30 4 * * * root /usr/local/bin/caddy-cert-export.sh >/dev/null 2>&1
CRON
success "Cert export installed."

# -----------------------------------------------------------------------------
# 6b. CDN trusted_proxies snippet + weekly refresh
# -----------------------------------------------------------------------------
info "Installing CDN ranges refresher..."
cat > /usr/local/bin/serverdeploy-cdn-refresh <<'CDN'
#!/bin/bash
# Refresh /etc/caddy/snippets/trusted_cdn.caddy with the current public CIDRs
# from major CDNs. Falls back to a static baked-in list when offline.
set -euo pipefail
OUT=/etc/caddy/snippets/trusted_cdn.caddy
TMP=$(mktemp); trap 'rm -f "${TMP}"' EXIT

fetch() { curl -fsS --max-time 8 "$1" 2>/dev/null || true; }

cf_v4=$(fetch https://www.cloudflare.com/ips-v4)
cf_v6=$(fetch https://www.cloudflare.com/ips-v6)
fastly=$(fetch https://api.fastly.com/public-ip-list | jq -r '.addresses[]?,.ipv6_addresses[]?' 2>/dev/null)
aws_cf=$(fetch https://ip-ranges.amazonaws.com/ip-ranges.json | jq -r '.prefixes[]? | select(.service=="CLOUDFRONT") | .ip_prefix' 2>/dev/null)
aws_cf6=$(fetch https://ip-ranges.amazonaws.com/ip-ranges.json | jq -r '.ipv6_prefixes[]? | select(.service=="CLOUDFRONT") | .ipv6_prefix' 2>/dev/null)
bunny=$(fetch https://bunnycdn.com/api/system/edgeserverlist/plain)

{
    echo "(trusted_cdn) {"
    echo "    servers {"
    echo "        trusted_proxies static \\"
    # Static baseline (Akamai, Sucuri, StackPath — no public JSON list)
    cat <<'STATIC'
            23.32.0.0/11 23.64.0.0/14 23.72.0.0/13 104.64.0.0/10 \
            184.24.0.0/13 184.50.0.0/15 184.84.0.0/14 \
            192.124.249.0/24 185.93.228.0/22 66.248.200.0/22 208.109.0.0/22 \
            151.139.0.0/19 \
STATIC
    add_block() {
        local data="$1"
        [[ -z "${data}" ]] && return 0
        echo "${data}" | awk 'NF{printf "            %s \\\n", $1}'
    }
    add_block "${cf_v4}"
    add_block "${cf_v6}"
    add_block "${fastly}"
    add_block "${aws_cf}"
    add_block "${aws_cf6}"
    add_block "${bunny}"
    # Trim trailing backslash from the very last line
    echo "            127.0.0.1/32 ::1/128"
    echo "    }"
    echo "}"
} > "${TMP}"

# Validate before swapping in
if /usr/local/bin/caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile --envfile /dev/null >/dev/null 2>&1; then
    install -m 0640 -o root -g caddy "${TMP}" "${OUT}"
    systemctl reload caddy 2>/dev/null || true
fi
CDN
chmod 755 /usr/local/bin/serverdeploy-cdn-refresh

# Initial snippet — minimal, no external fetch yet (no jq guarantee at this stage).
# 45-geoip stage and the weekly cron will replace it with the live list.
if [[ ! -f "${CADDY_CONF}/snippets/trusted_cdn.caddy" ]]; then
    cat > "${CADDY_CONF}/snippets/trusted_cdn.caddy" <<'TC'
(trusted_cdn) {
    servers {
        trusted_proxies static 127.0.0.1/32 ::1/128
    }
}
TC
fi
chown root:caddy "${CADDY_CONF}/snippets/trusted_cdn.caddy"
chmod 640 "${CADDY_CONF}/snippets/trusted_cdn.caddy"

cat > /etc/cron.d/serverdeploy-cdn-refresh <<'CRON'
# Refresh CDN trusted_proxies list weekly
30 5 * * 0 root /usr/local/bin/serverdeploy-cdn-refresh >> /var/log/serverdeploy/cdn-refresh.log 2>&1
CRON
chmod 644 /etc/cron.d/serverdeploy-cdn-refresh
success "CDN trusted_proxies refresher installed."

# -----------------------------------------------------------------------------
# 6c. GeoIP block snippet (rendered by geoblock.sh; placeholder for now)
# -----------------------------------------------------------------------------
if [[ ! -f "${CADDY_CONF}/snippets/geoblock.caddy" ]]; then
    # No-op placeholder; geoblock.sh and 45-geoip.sh fill it in.
    cat > "${CADDY_CONF}/snippets/geoblock.caddy" <<'GB'
(geoblock) {
    # GeoIP disabled or not yet configured. No-op snippet so 'import geoblock'
    # in site files keeps working until 45-geoip.sh runs and geoblock.sh
    # rewrites this file.
}
GB
fi
chown root:caddy "${CADDY_CONF}/snippets/geoblock.caddy"
chmod 640 "${CADDY_CONF}/snippets/geoblock.caddy"

# -----------------------------------------------------------------------------
# 7. systemd unit
# -----------------------------------------------------------------------------
info "Writing caddy systemd unit..."
cat > /etc/systemd/system/caddy.service <<EOF
[Unit]
Description=Caddy web server
Documentation=https://caddyserver.com/docs/
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=${CADDY_USER}
Group=${CADDY_GROUP}
ExecStart=${CADDY_BIN} run --environ --config ${CADDY_CONF}/Caddyfile
ExecReload=${CADDY_BIN} reload --config ${CADDY_CONF}/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
NoNewPrivileges=true
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
ReadWritePaths=${CADDY_HOME} ${CADDY_LOG} /etc/stalwart/certs

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable caddy

# `caddy validate` (run as root above) opens the global log file and creates
# /var/log/caddy/caddy.log as root:root 0600. Re-chown so the caddy user can
# append to it once systemd starts the daemon under User=caddy.
chown -R "${CADDY_USER}:${CADDY_GROUP}" "${CADDY_LOG}"

systemctl restart caddy
sleep 2
systemctl is-active --quiet caddy || die "Caddy failed to start. journalctl -u caddy -n 50"
success "Caddy running."

echo
success "10-caddy.sh complete."
info "  Binary  : ${CADDY_BIN}"
info "  Config  : ${CADDY_CONF}/Caddyfile"
info "  CRS     : ${CRS_DIR}"
info "  Logs    : ${CADDY_LOG}/"
