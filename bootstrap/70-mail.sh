#!/bin/bash
# =============================================================================
# 70-mail.sh — Stalwart Mail Server (inbound user mail)
#
# Architecture:
#   - Stalwart handles inbound mail to client domains, direct outbound on :25.
#   - Caddy reverse-proxies ${MAIL_ADMIN_HOST} → Stalwart admin (:8090) with
#     IP allowlist + HTTP basic auth + rate limit.
#   - ${SERVER_HOSTNAME} is the HELO identity; Stalwart reads its TLS cert from
#     /etc/stalwart/certs/${SERVER_HOSTNAME}/{fullchain.pem,privkey.pem}, which
#     /usr/local/bin/caddy-cert-export.sh refreshes daily.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${REPO_DIR}/lib/common.sh"

require_root
load_config

[[ -n "${SERVER_HOSTNAME:-}" ]]      || die "SERVER_HOSTNAME missing — run 00-base.sh first."
[[ -n "${MAIL_ADMIN_HOST:-}" ]]      || die "MAIL_ADMIN_HOST missing."
[[ -n "${MAIL_ADMIN_ALLOWLIST:-}" ]] || die "MAIL_ADMIN_ALLOWLIST missing."

STALWART_PREFIX=/opt/stalwart
STALWART_CONFIG=${STALWART_PREFIX}/etc/config.toml
STALWART_BIN=${STALWART_PREFIX}/bin/stalwart
ADMIN_PASS_FILE=/etc/serverdeploy/stalwart-admin.txt
INSTALL_LOG=/var/log/serverdeploy/stalwart-install.log
CADDY_SITES=/etc/caddy/sites
CERT_DIR="/etc/stalwart/certs/${SERVER_HOSTNAME}"
STALWART_HTTP_PORT=8090

mkdir -p /var/log/serverdeploy

# -----------------------------------------------------------------------------
# 1. Install Stalwart
# -----------------------------------------------------------------------------
if [[ -x "${STALWART_BIN}" ]]; then
    info "Stalwart already installed at ${STALWART_PREFIX}"
else
    info "Downloading Stalwart installer..."
    INSTALLER="$(mktemp)"
    curl --proto '=https' --tlsv1.2 -fsSL https://get.stalw.art/install.sh -o "${INSTALLER}" || \
        die "Failed to download Stalwart installer."
    chmod +x "${INSTALLER}"
    info "Running Stalwart installer (output → ${INSTALL_LOG})..."
    if sh "${INSTALLER}" "${STALWART_PREFIX}" >"${INSTALL_LOG}" 2>&1; then
        success "Stalwart installed."
    else
        cat "${INSTALL_LOG}" >&2
        die "Stalwart installer failed — see ${INSTALL_LOG}"
    fi
    rm -f "${INSTALLER}"
fi

[[ -f "${STALWART_CONFIG}" ]] || die "Stalwart config not found at ${STALWART_CONFIG}"

# -----------------------------------------------------------------------------
# 2. Capture admin password
# -----------------------------------------------------------------------------
if [[ ! -f "${ADMIN_PASS_FILE}" ]]; then
    if [[ -f "${INSTALL_LOG}" ]]; then
        ADMIN_PASS=$(sed -n "s/.*password '\([^']*\)'.*/\1/p" "${INSTALL_LOG}" | head -1)
        if [[ -n "${ADMIN_PASS}" ]]; then
            printf 'admin: %s\n' "${ADMIN_PASS}" > "${ADMIN_PASS_FILE}"
            chmod 600 "${ADMIN_PASS_FILE}"
            chown root:root "${ADMIN_PASS_FILE}"
            success "Admin password saved → ${ADMIN_PASS_FILE}"
        else
            warn "Could not extract admin password — grep ${INSTALL_LOG} manually."
        fi
    fi
else
    info "Admin password file already exists."
fi

# -----------------------------------------------------------------------------
# 3. Cert export
# -----------------------------------------------------------------------------
info "Exporting Caddy certs for Stalwart..."
/usr/local/bin/caddy-cert-export.sh || warn "Cert export returned non-zero (continuing)."
if [[ -f "${CERT_DIR}/fullchain.pem" && -f "${CERT_DIR}/privkey.pem" ]]; then
    success "Cert present at ${CERT_DIR}/"
else
    warn "Cert not yet at ${CERT_DIR}/ — Caddy may still be issuing it."
fi

# -----------------------------------------------------------------------------
# 4. Wire Stalwart TLS + bind
# -----------------------------------------------------------------------------
info "Wiring Stalwart TLS + bind..."
[[ -f "${STALWART_CONFIG}.serverdeploy.bak" ]] || cp "${STALWART_CONFIG}" "${STALWART_CONFIG}.serverdeploy.bak"
sed -i \
    -e "s|^cert *=.*|cert = \"%{file:${CERT_DIR}/fullchain.pem}%\"|" \
    -e "s|^private-key *=.*|private-key = \"%{file:${CERT_DIR}/privkey.pem}%\"|" \
    "${STALWART_CONFIG}"
# Strip [server.listener.https] block — Caddy is the public TLS endpoint
sed -i '/^\[server\.listener\.https\]/,/^$/d' "${STALWART_CONFIG}"
# HTTP admin → 127.0.0.1:8090
sed -i "s|^bind = \"\\[::\\]:8080\"$|bind = \"127.0.0.1:${STALWART_HTTP_PORT}\"|" "${STALWART_CONFIG}"
success "Stalwart bound to 127.0.0.1:${STALWART_HTTP_PORT}, HTTPS listener removed."

if id stalwart >/dev/null 2>&1; then
    chown -R stalwart:stalwart /etc/stalwart/certs 2>/dev/null || true
fi

# -----------------------------------------------------------------------------
# 5. Caddy site for mail admin (allowlist + basic auth + rate limit)
# -----------------------------------------------------------------------------
MAIL_BASIC_FILE=/etc/serverdeploy/mail-basic-auth.txt
if [[ ! -f "${MAIL_BASIC_FILE}" ]]; then
    BASIC_PASS=$(random_password 24)
    BASIC_HASH=$(/usr/local/bin/caddy hash-password --plaintext "${BASIC_PASS}")
    printf 'user: admin\npassword: %s\nbcrypt: %s\n' "${BASIC_PASS}" "${BASIC_HASH}" > "${MAIL_BASIC_FILE}"
    chmod 600 "${MAIL_BASIC_FILE}"
    success "Mail admin basic-auth → ${MAIL_BASIC_FILE}"
fi
BASIC_HASH=$(awk '/^bcrypt:/ {sub(/^bcrypt: /,""); print}' "${MAIL_BASIC_FILE}")

info "Writing Caddy site for ${MAIL_ADMIN_HOST}..."
mkdir -p "${CADDY_SITES}"
cat > "${CADDY_SITES}/${MAIL_ADMIN_HOST}.caddy" <<CADDY
${MAIL_ADMIN_HOST} {
    import waf
    import secure_headers
    import geoblock
    encode zstd gzip

    @allowed remote_ip ${MAIL_ADMIN_ALLOWLIST}

    rate_limit {
        zone mail_admin_zone {
            key {client_ip}
            events 30
            window 1m
        }
    }

    handle @allowed {
        basic_auth {
            admin ${BASIC_HASH}
        }
        reverse_proxy 127.0.0.1:${STALWART_HTTP_PORT}
    }

    handle {
        abort
    }

    log {
        output file /var/log/caddy/${MAIL_ADMIN_HOST}.log
    }
}
CADDY
chown root:caddy "${CADDY_SITES}/${MAIL_ADMIN_HOST}.caddy"
chmod 640 "${CADDY_SITES}/${MAIL_ADMIN_HOST}.caddy"
success "Caddy site written → ${CADDY_SITES}/${MAIL_ADMIN_HOST}.caddy"

if /usr/local/bin/caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
    systemctl reload caddy && success "Caddy reloaded." || warn "Caddy reload failed."
else
    die "Caddyfile validation failed."
fi

# -----------------------------------------------------------------------------
# 6. Start Stalwart
# -----------------------------------------------------------------------------
info "Enabling and (re)starting Stalwart..."
systemctl enable stalwart 2>/dev/null || true
systemctl restart stalwart || die "Stalwart failed to start. journalctl -u stalwart -n 50"
sleep 2
systemctl is-active --quiet stalwart || die "Stalwart not active."
success "Stalwart running."

echo
success "70-mail.sh complete."
info "  Admin URL  : https://${MAIL_ADMIN_HOST}/login"
info "  Allowed    : ${MAIL_ADMIN_ALLOWLIST}"
info "  Stalwart   : ${ADMIN_PASS_FILE}"
info "  Basic auth : ${MAIL_BASIC_FILE}"
