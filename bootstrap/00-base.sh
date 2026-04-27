#!/bin/bash
# =============================================================================
# 00-base.sh — base system setup
#   - dnf upgrade + base packages (vim, ed, inotify-tools, nss-tools, ...)
#   - state directories under /etc/serverdeploy and /srv
#   - first-run prompts: admin email, hostname, timezone, DKIM selector,
#     mail-admin host + allowlist, DB tooling (phpMyAdmin / pgAdmin4 / both /
#     none), outbound mail relay (Resend API / Resend SMTP / Generic SMTP /
#     None), Backblaze B2 creds
#   - sysctl drop-in (UDP buffers for QUIC, syncookies, somaxconn)
#   - timezone applied via timedatectl
#   - msmtp (or serverdeploy-mail wrapper for Resend API) wired in;
#     sendmail symlink points at the chosen transport
#   - dnf-automatic for security updates
#   - root SSH key install, sshd hardening, firewalld rules
#   - test email
#
# Honors LOCK_SSH=1: removes port 22 from sshd + firewalld.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${REPO_DIR}/lib/common.sh"

require_root

CONFIG_FILE=/etc/serverdeploy/config

# -----------------------------------------------------------------------------
# Pre-flight
# -----------------------------------------------------------------------------
[[ -f /etc/almalinux-release ]] || warn "Not AlmaLinux — proceeding anyway."

HOSTNAME_FQDN="$(hostname -f 2>/dev/null || true)"
if [[ -z "${HOSTNAME_FQDN}" || ! "${HOSTNAME_FQDN}" =~ \. ]]; then
    warn "Hostname is not a FQDN: '${HOSTNAME_FQDN:-<empty>}'"
    warn "Set with: hostnamectl set-hostname <host>.<domain>"
    prompt FQDN_OK "Continue anyway? (y/N)" "n"
    [[ "${FQDN_OK,,}" =~ ^y ]] || die "Aborted — set the FQDN first."
fi
info "Hostname: ${HOSTNAME_FQDN:-<unset>}"

mkdir -p /etc/serverdeploy/sites /var/log/serverdeploy

# -----------------------------------------------------------------------------
# First-run prompts (skipped on re-run)
# -----------------------------------------------------------------------------
if [[ -f "${CONFIG_FILE}" ]]; then
    info "Loading existing config from ${CONFIG_FILE}..."
    load_config
    SSH_PORT_NEW="${SSH_PORT:-2223}"
    SSH_KEY="${SSH_KEY:-}"
else
    echo
    info "=== First-time setup ==="
    info "Every secret is stored in ${CONFIG_FILE} (mode 600 root:root)."
    echo

    # ---- Identity ----
    while :; do
        prompt_required ADMIN_EMAIL "Admin email (alerts go here)"
        valid_email "${ADMIN_EMAIL}" && break
        warn "Invalid email."
    done
    prompt MAIL_FROM_NAME "Sender display name" "$(hostname -s)"
    prompt MAIL_FROM_ADDR "Sender 'From' address" "${ADMIN_EMAIL}"
    valid_email "${MAIL_FROM_ADDR}" || die "Invalid From address."

    # ---- Server hostname ----
    prompt SERVER_HOSTNAME "Server hostname (FQDN)" "${HOSTNAME_FQDN}"
    valid_domain "${SERVER_HOSTNAME}" || die "Invalid FQDN: ${SERVER_HOSTNAME}"

    # ---- Timezone ----
    prompt TIMEZONE "Timezone (IANA, e.g. UTC, America/New_York)" "UTC"
    if ! timedatectl list-timezones 2>/dev/null | grep -qx "${TIMEZONE}"; then
        warn "'${TIMEZONE}' not in timedatectl list-timezones — accepting anyway (may fail on apply)."
    fi

    # ---- SSH ----
    echo
    prompt_required SSH_KEY "SSH public key (paste the full single line)"
    while :; do
        prompt SSH_PORT_NEW "SSH port" "2223"
        valid_port "${SSH_PORT_NEW}" && break
        warn "Invalid port."
    done

    # ---- Mail admin panel ----
    echo
    info "Mail admin panel (Stalwart web UI) — IP-allowlisted only."
    DOMAIN_PART="${SERVER_HOSTNAME#*.}"
    prompt MAIL_ADMIN_HOST "Mail admin panel hostname" "mail.${DOMAIN_PART}"
    valid_domain "${MAIL_ADMIN_HOST}" || die "Invalid FQDN."
    while :; do
        prompt_required MAIL_ADMIN_ALLOWLIST "Admin allowlist (IP/CIDR, comma-separated; v4+v6 both OK)"
        ok=1
        IFS=',' read -ra entries <<<"${MAIL_ADMIN_ALLOWLIST}"
        for e in "${entries[@]}"; do
            e="${e//[[:space:]]/}"
            valid_ip_or_cidr "${e}" || { warn "Invalid: '${e}'"; ok=0; break; }
        done
        [[ ${ok} -eq 1 ]] && break
    done

    # ---- DKIM selector ----
    prompt DKIM_SELECTOR "DKIM selector (per-server)" "default"

    # ---- DB admin tooling ----
    echo
    info "Database admin tooling (optional — extra attack surface, allowlisted+basic-auth)"
    info "  1) phpMyAdmin (MariaDB)"
    info "  2) pgAdmin4   (Postgres)"
    info "  3) Both"
    info "  4) None"
    while :; do
        prompt TOOLS_CHOICE "Choice [1-4]" "4"
        case "${TOOLS_CHOICE}" in 1|2|3|4) break ;; *) warn "Pick 1-4." ;; esac
    done
    INSTALL_PMA="no"
    INSTALL_PGA="no"
    PMA_HOST=""
    PGA_HOST=""
    case "${TOOLS_CHOICE}" in
        1) INSTALL_PMA="yes" ;;
        2) INSTALL_PGA="yes" ;;
        3) INSTALL_PMA="yes"; INSTALL_PGA="yes" ;;
    esac
    if [[ "${INSTALL_PMA}" == "yes" ]]; then
        prompt PMA_HOST "phpMyAdmin hostname" "pma.${DOMAIN_PART}"
        valid_domain "${PMA_HOST}" || die "Invalid FQDN."
    fi
    if [[ "${INSTALL_PGA}" == "yes" ]]; then
        prompt PGA_HOST "pgAdmin4 hostname" "pga.${DOMAIN_PART}"
        valid_domain "${PGA_HOST}" || die "Invalid FQDN."
    fi

    # ---- Outbound mail relay ----
    echo
    info "Outbound mail relay (sends alerts + system mail):"
    info "  1) Resend (recommended)"
    info "  2) Generic SMTP"
    info "  3) None  (alerts logged to journal + /var/log/serverdeploy/alerts.log only)"
    while :; do
        prompt RELAY_CHOICE "Choice [1-3]" "1"
        case "${RELAY_CHOICE}" in 1|2|3) break ;; *) warn "Pick 1-3." ;; esac
    done
    SMTP_RELAY="none"
    SMTP_HOST=""
    SMTP_PORT=""
    SMTP_USER=""
    SMTP_PASS=""
    SMTP_TLS=""
    SMTP_FROM=""
    RESEND_API_KEY=""
    case "${RELAY_CHOICE}" in
        1)
            info "Resend transport:"
            info "  1) API key (HTTPS POST — recommended, no SMTP port required)"
            info "  2) SMTP    (smtp.resend.com:587, STARTTLS)"
            while :; do
                prompt RESEND_MODE "Choice [1-2]" "1"
                case "${RESEND_MODE}" in 1|2) break ;; *) warn "Pick 1-2." ;; esac
            done
            prompt_secret RESEND_API_KEY "Resend API key (re_...)"
            [[ -n "${RESEND_API_KEY}" ]] || die "API key cannot be empty."
            if [[ "${RESEND_MODE}" == "1" ]]; then
                SMTP_RELAY="resend-api"
            else
                SMTP_RELAY="resend-smtp"
                SMTP_HOST="smtp.resend.com"
                SMTP_PORT="587"
                SMTP_USER="resend"
                SMTP_PASS="${RESEND_API_KEY}"
                SMTP_TLS="starttls"
                SMTP_FROM="${MAIL_FROM_ADDR}"
            fi
            ;;
        2)
            SMTP_RELAY="generic"
            prompt_required SMTP_HOST "SMTP host"
            while :; do
                prompt SMTP_PORT "SMTP port" "587"
                valid_port "${SMTP_PORT}" && break
                warn "Invalid port."
            done
            prompt SMTP_USER "SMTP username (blank for none)" ""
            if [[ -n "${SMTP_USER}" ]]; then
                prompt_secret SMTP_PASS "SMTP password"
            fi
            info "TLS modes: starttls (587), tls (465), none (only allowed on 127.0.0.1)"
            while :; do
                prompt SMTP_TLS "TLS mode" "starttls"
                case "${SMTP_TLS}" in starttls|tls|none) break ;; *) warn "Pick starttls/tls/none." ;; esac
            done
            if [[ "${SMTP_TLS}" == "none" && "${SMTP_HOST}" != "127.0.0.1" && "${SMTP_HOST}" != "localhost" ]]; then
                die "Refusing TLS=none for non-loopback host '${SMTP_HOST}'."
            fi
            prompt SMTP_FROM "Envelope From" "${MAIL_FROM_ADDR}"
            ;;
        3)
            SMTP_RELAY="none"
            warn "Alerts will go to journal + /var/log/serverdeploy/alerts.log only."
            ;;
    esac

    # ---- GeoIP block ----
    echo
    info "GeoIP country block (CrowdSec + Caddy maxmind_geolocation)"
    info "Default rule = ALLOW, only block listed countries (mode=block)."
    prompt_yes_no GEOIP_ENABLED "Enable GeoIP block?" "y"
    GEOIP_MODE="block"
    GEOIP_COUNTRIES=""
    GEOIP_SOURCE=""
    MAXMIND_LICENSE_KEY=""
    MAXMIND_ACCOUNT_ID=""
    MAXMIND_OFFLINE_DIR=""
    if [[ "${GEOIP_ENABLED}" == "yes" ]]; then
        info "MaxMind data source:"
        info "  1) Offline files (you provide a path with GeoLite2-Country.mmdb)"
        info "  2) API (geoipupdate via license key — auto-refresh weekly)"
        while :; do
            prompt MMDB_CHOICE "Choice [1-2]" "1"
            case "${MMDB_CHOICE}" in 1|2) break ;; *) warn "Pick 1-2." ;; esac
        done
        if [[ "${MMDB_CHOICE}" == "1" ]]; then
            GEOIP_SOURCE="offline"
            while :; do
                prompt_required MAXMIND_OFFLINE_DIR "Path to dir containing GeoLite2-Country.mmdb"
                if [[ -f "${MAXMIND_OFFLINE_DIR}/GeoLite2-Country.mmdb" ]]; then
                    break
                fi
                warn "${MAXMIND_OFFLINE_DIR}/GeoLite2-Country.mmdb not found."
            done
        else
            GEOIP_SOURCE="api"
            prompt_required MAXMIND_ACCOUNT_ID  "MaxMind account ID"
            prompt_secret    MAXMIND_LICENSE_KEY "MaxMind license key"
        fi
        prompt GEOIP_COUNTRIES "Initial country list (ISO-2, comma-separated)" \
            "RU,CN,BY,AU,IN,NG,KP"
    fi

    # ---- Backblaze B2 ----
    echo
    info "Backblaze B2 backups (leave empty to configure later)"
    prompt B2_BUCKET "B2 bucket name" ""
    B2_ACCOUNT_ID=""
    B2_ACCOUNT_KEY=""
    if [[ -n "${B2_BUCKET}" ]]; then
        prompt_required B2_ACCOUNT_ID  "B2 application key ID"
        prompt_secret    B2_ACCOUNT_KEY "B2 application key"
    fi

    echo
    info "Credentials collected. Continuing with bootstrap..."
fi

# -----------------------------------------------------------------------------
# 1. System update + base packages
# -----------------------------------------------------------------------------
info "Updating system..."
dnf -y upgrade --refresh

info "Installing base packages..."
dnf -y install epel-release
dnf -y install \
    vim-enhanced curl wget git unzip tar gcc make socat \
    openssl ca-certificates msmtp logrotate cronie \
    restic jq dnf-automatic firewalld policycoreutils-python-utils \
    bind-utils rsync nmap-ncat tar \
    ed inotify-tools nss-tools \
    chrony iproute procps-ng iputils
success "Base packages installed."

# -----------------------------------------------------------------------------
# 2. State directories
# -----------------------------------------------------------------------------
info "Creating state directories..."
mkdir -p /etc/serverdeploy/sites
mkdir -p /srv/sites
mkdir -p /srv/backups/dumps /srv/backups/archived
mkdir -p /var/log/serverdeploy
mkdir -p /usr/local/lib/serverdeploy
mkdir -p /var/lib/serverdeploy/alerts
chmod 750 /etc/serverdeploy /srv/backups
chmod 700 /var/lib/serverdeploy/alerts
success "State directories created."

# Install lib helpers system-wide
install -m 0644 "${REPO_DIR}/lib/common.sh"    /usr/local/lib/serverdeploy/common.sh
install -m 0644 "${REPO_DIR}/lib/notify.sh"    /usr/local/lib/serverdeploy/notify.sh
install -m 0644 "${REPO_DIR}/lib/port-pool.sh" /usr/local/lib/serverdeploy/port-pool.sh
success "Libs installed → /usr/local/lib/serverdeploy/"

# Symlink top-level commands so admins can invoke them by short name
info "Linking commands into /usr/local/bin/..."
for cmd in newsite delsite listsite siteuser waf-whitelist adminip geoblock restoresite update-caddy stalwart-passwd; do
    src="${REPO_DIR}/${cmd}.sh"
    if [[ -x "${src}" ]]; then
        ln -sf "${src}" "/usr/local/bin/${cmd}"
    fi
done
success "Commands linked."

# -----------------------------------------------------------------------------
# 3. Write /etc/serverdeploy/config (only on first run)
# -----------------------------------------------------------------------------
if [[ ! -f "${CONFIG_FILE}" ]]; then
    info "Writing ${CONFIG_FILE}..."
    cat > "${CONFIG_FILE}" <<EOF
# serverdeploy global config
# Generated by 00-base.sh on $(date -Iseconds)
# Mode 600 — contains secrets.

# === Admin / mail identity ===
ADMIN_EMAIL="${ADMIN_EMAIL}"
MAIL_FROM_NAME="${MAIL_FROM_NAME}"
MAIL_FROM_ADDR="${MAIL_FROM_ADDR}"

# === Server identity ===
SERVER_HOSTNAME="${SERVER_HOSTNAME}"
TIMEZONE="${TIMEZONE}"
DKIM_SELECTOR="${DKIM_SELECTOR}"

# === Outbound mail relay ===
# SMTP_RELAY: resend-api | resend-smtp | generic | none
SMTP_RELAY="${SMTP_RELAY}"
RESEND_API_KEY="${RESEND_API_KEY}"
SMTP_HOST="${SMTP_HOST}"
SMTP_PORT="${SMTP_PORT}"
SMTP_USER="${SMTP_USER}"
SMTP_PASS="${SMTP_PASS}"
SMTP_TLS="${SMTP_TLS}"
SMTP_FROM="${SMTP_FROM}"

# === Mail (Stalwart) admin panel ===
MAIL_ADMIN_HOST="${MAIL_ADMIN_HOST}"
MAIL_ADMIN_ALLOWLIST="${MAIL_ADMIN_ALLOWLIST}"

# === DB admin tools ===
INSTALL_PMA="${INSTALL_PMA}"
INSTALL_PGA="${INSTALL_PGA}"
PMA_HOST="${PMA_HOST}"
PGA_HOST="${PGA_HOST}"

# === Backups (Backblaze B2) ===
B2_ACCOUNT_ID="${B2_ACCOUNT_ID}"
B2_ACCOUNT_KEY="${B2_ACCOUNT_KEY}"
B2_BUCKET="${B2_BUCKET}"

# === SSH ===
SSH_PORT="${SSH_PORT_NEW}"
SSH_KEY="${SSH_KEY}"

# === WAF ===
WAF_PARANOIA="1"

# === GeoIP block ===
# GEOIP_SOURCE: offline | api  (empty if disabled)
GEOIP_ENABLED="${GEOIP_ENABLED}"
GEOIP_MODE="${GEOIP_MODE}"
GEOIP_COUNTRIES="${GEOIP_COUNTRIES}"
GEOIP_SOURCE="${GEOIP_SOURCE}"
MAXMIND_ACCOUNT_ID="${MAXMIND_ACCOUNT_ID}"
MAXMIND_LICENSE_KEY="${MAXMIND_LICENSE_KEY}"
MAXMIND_OFFLINE_DIR="${MAXMIND_OFFLINE_DIR}"
GEOIP_BYPASS_IPS=""
EOF
    chmod 600 "${CONFIG_FILE}"
    chown root:root "${CONFIG_FILE}"
    success "Wrote ${CONFIG_FILE}"
else
    info "Config already exists at ${CONFIG_FILE}"
fi

# Re-load so SMTP_RELAY etc. are visible below
load_config

# -----------------------------------------------------------------------------
# 4. Timezone
# -----------------------------------------------------------------------------
if [[ -n "${TIMEZONE:-}" ]]; then
    info "Setting timezone to ${TIMEZONE}..."
    timedatectl set-timezone "${TIMEZONE}" 2>/dev/null || warn "Could not set timezone (continuing)."
fi

# -----------------------------------------------------------------------------
# 5. sysctl: QUIC UDP buffers, syncookies, somaxconn
# -----------------------------------------------------------------------------
info "Writing sysctl drop-in (UDP buffers, network hardening)..."
cat > /etc/sysctl.d/99-serverdeploy.conf <<'SYSCTL'
# serverdeploy network tunings
# QUIC/HTTP3 needs ~7.5MB receive buffer to avoid quic-go warnings
net.core.rmem_max = 7500000
net.core.wmem_max = 7500000
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 5000
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
kernel.dmesg_restrict = 1
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
SYSCTL
sysctl --system >/dev/null
success "sysctl applied."

# -----------------------------------------------------------------------------
# 6. Mail transport wiring
# -----------------------------------------------------------------------------
configure_mail_transport() {
    local relay="${SMTP_RELAY:-none}"

    # Always remove stale wrapper / msmtprc before rewriting
    rm -f /usr/local/bin/serverdeploy-mail
    rm -f /etc/msmtprc

    case "${relay}" in
        resend-api)
            info "Wiring serverdeploy-mail wrapper for Resend API..."
            cat > /usr/local/bin/serverdeploy-mail <<'WRAPPER'
#!/bin/bash
# serverdeploy-mail — sendmail-compatible wrapper that POSTs to Resend's API.
# Reads RFC822-ish stdin: From:, To:, Subject:, blank line, body.
# Honors -t (parse To from headers — we always do this).
set -euo pipefail
CONFIG=/etc/serverdeploy/config
[[ -f "${CONFIG}" ]] || { echo "missing ${CONFIG}" >&2; exit 1; }
# shellcheck disable=SC1090
source "${CONFIG}"

[[ -n "${RESEND_API_KEY:-}" ]] || { echo "RESEND_API_KEY missing" >&2; exit 1; }

LOG=/var/log/serverdeploy/mail.log
mkdir -p "$(dirname "${LOG}")"

# Read stdin
input="$(cat)"

# Split headers / body on first blank line
headers="${input%%$'\n\n'*}"
body="${input#*$'\n\n'}"
[[ "${headers}" == "${input}" ]] && body=""   # no body separator

extract_header() {
    local name="$1"
    echo "${headers}" | awk -v n="${name}:" 'BEGIN{IGNORECASE=1} $0 ~ "^"n {sub("^"n"[[:space:]]*",""); print; exit}'
}

from_raw="$(extract_header From)"
to_raw="$(extract_header To)"
subject="$(extract_header Subject)"

# from_raw might be "Name <addr>" — pass straight through
[[ -n "${from_raw}" ]] || from_raw="${MAIL_FROM_NAME:-serverdeploy} <${MAIL_FROM_ADDR:-root@localhost}>"
[[ -n "${to_raw}" ]] || to_raw="${ADMIN_EMAIL:-root}"
[[ -n "${subject}" ]] || subject="(no subject)"

# Build JSON. body might contain quotes/newlines — let jq escape it.
payload=$(jq -nc \
    --arg from "${from_raw}" \
    --arg to "${to_raw}" \
    --arg subject "${subject}" \
    --arg text "${body}" \
    '{from:$from,to:[$to],subject:$subject,text:$text}')

if curl -fsS --max-time 10 --retry 2 \
        -H "Authorization: Bearer ${RESEND_API_KEY}" \
        -H "Content-Type: application/json" \
        -X POST https://api.resend.com/emails \
        -d "${payload}" >/dev/null 2>>"${LOG}"; then
    echo "[$(date -Iseconds)] OK  to=${to_raw} subj=${subject}" >> "${LOG}"
    exit 0
else
    echo "[$(date -Iseconds)] ERR to=${to_raw} subj=${subject}" >> "${LOG}"
    exit 1
fi
WRAPPER
            chmod 755 /usr/local/bin/serverdeploy-mail
            chown root:root /usr/local/bin/serverdeploy-mail

            # sendmail symlink → wrapper
            [[ -e /usr/sbin/sendmail && ! -L /usr/sbin/sendmail ]] && \
                mv /usr/sbin/sendmail /usr/sbin/sendmail.dist 2>/dev/null || true
            ln -sf /usr/local/bin/serverdeploy-mail /usr/sbin/sendmail
            success "Resend API transport wired."
            ;;

        resend-smtp|generic)
            info "Configuring msmtp for ${relay}..."
            local tls_lines=""
            case "${SMTP_TLS}" in
                starttls) tls_lines="tls            on
tls_starttls   on
tls_trust_file /etc/pki/tls/certs/ca-bundle.crt" ;;
                tls)      tls_lines="tls            on
tls_starttls   off
tls_trust_file /etc/pki/tls/certs/ca-bundle.crt" ;;
                none)     tls_lines="tls            off
tls_starttls   off" ;;
            esac
            local auth_block=""
            if [[ -n "${SMTP_USER}" ]]; then
                auth_block="auth           on
user           ${SMTP_USER}
password       ${SMTP_PASS}"
            else
                auth_block="auth           off"
            fi
            cat > /etc/msmtprc <<EOF
# Generated by serverdeploy 00-base.sh
defaults
${tls_lines}
logfile        /var/log/msmtp.log

account        primary
host           ${SMTP_HOST}
port           ${SMTP_PORT}
from           ${SMTP_FROM:-${MAIL_FROM_ADDR}}
${auth_block}

account default : primary
EOF
            chmod 600 /etc/msmtprc
            chown root:root /etc/msmtprc
            [[ -e /usr/sbin/sendmail && ! -L /usr/sbin/sendmail ]] && \
                mv /usr/sbin/sendmail /usr/sbin/sendmail.dist 2>/dev/null || true
            ln -sf /usr/bin/msmtp /usr/sbin/sendmail
            success "msmtp configured (${relay} → ${SMTP_HOST}:${SMTP_PORT})."
            ;;

        none)
            info "No relay configured — alerts will log only."
            # Provide a sendmail symlink that swallows input + logs to the alerts log
            cat > /usr/local/bin/serverdeploy-mail <<'NULLER'
#!/bin/bash
LOG=/var/log/serverdeploy/alerts.log
mkdir -p "$(dirname "${LOG}")"
{
    echo "[$(date -Iseconds)] mail dropped (SMTP_RELAY=none):"
    cat
    echo "---"
} >> "${LOG}"
exit 0
NULLER
            chmod 755 /usr/local/bin/serverdeploy-mail
            [[ -e /usr/sbin/sendmail && ! -L /usr/sbin/sendmail ]] && \
                mv /usr/sbin/sendmail /usr/sbin/sendmail.dist 2>/dev/null || true
            ln -sf /usr/local/bin/serverdeploy-mail /usr/sbin/sendmail
            ;;

        *)
            die "Unknown SMTP_RELAY: ${relay}"
            ;;
    esac
}
configure_mail_transport

# -----------------------------------------------------------------------------
# 7. dnf-automatic
# -----------------------------------------------------------------------------
info "Configuring dnf-automatic for security updates..."
cat > /etc/dnf/automatic.conf <<EOF
[commands]
upgrade_type = security
random_sleep = 0
network_online_timeout = 60
download_updates = yes
apply_updates = yes
reboot = never

[emitters]
emit_via = email,stdio

[email]
email_from = ${MAIL_FROM_ADDR}
email_to = ${ADMIN_EMAIL}
email_host = localhost

[base]
debuglevel = 1
EOF
systemctl enable --now dnf-automatic.timer
success "dnf-automatic enabled."

# -----------------------------------------------------------------------------
# 8. SSH key install
# -----------------------------------------------------------------------------
info "Installing root SSH key..."
mkdir -p /root/.ssh
chmod 700 /root/.ssh
touch /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

if grep -qF "${SSH_KEY}" /root/.ssh/authorized_keys 2>/dev/null; then
    info "SSH key already present."
else
    echo "${SSH_KEY}" >> /root/.ssh/authorized_keys
    success "SSH key appended."
fi

SSH_KEY_FP="$(echo "${SSH_KEY}" | awk '{print $2}')"
[[ -n "${SSH_KEY_FP}" ]] || die "SSH key empty."
grep -qF "${SSH_KEY_FP}" /root/.ssh/authorized_keys || die "SSH key verification failed."
success "SSH key verified."

# -----------------------------------------------------------------------------
# 9. SELinux: SSH port label
# -----------------------------------------------------------------------------
if command -v semanage >/dev/null 2>&1 && getenforce 2>/dev/null | grep -qE 'Enforcing|Permissive'; then
    info "Configuring SELinux for SSH port ${SSH_PORT_NEW}..."
    if ! semanage port -l 2>/dev/null | grep -qE "^ssh_port_t .* ${SSH_PORT_NEW}(,|$)"; then
        semanage port -a -t ssh_port_t -p tcp "${SSH_PORT_NEW}" 2>/dev/null || \
            semanage port -m -t ssh_port_t -p tcp "${SSH_PORT_NEW}" 2>/dev/null || true
    fi
    success "SELinux ssh_port_t includes ${SSH_PORT_NEW}."
fi

# -----------------------------------------------------------------------------
# 10. sshd hardening
# -----------------------------------------------------------------------------
info "Hardening sshd..."
SSHD_CONF=/etc/ssh/sshd_config.d/00-serverdeploy.conf
{
    echo "# Managed by serverdeploy 00-base.sh — $(date -Iseconds)"
    [[ "${LOCK_SSH:-0}" -ne 1 ]] && echo "Port 22"
    echo "Port ${SSH_PORT_NEW}"
    cat <<'EOF'
PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
MaxAuthTries 3
MaxSessions 3
MaxStartups 3:30:10
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
TCPKeepAlive yes
LogLevel VERBOSE
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,sntrup761x25519-sha512@openssh.com
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
HostKeyAlgorithms ssh-ed25519,rsa-sha2-512
EOF
} > "${SSHD_CONF}"
chmod 644 "${SSHD_CONF}"

sshd -t || die "sshd config invalid — not restarting."
systemctl restart sshd

if [[ "${LOCK_SSH:-0}" -eq 1 ]]; then
    success "sshd hardened — port ${SSH_PORT_NEW} only."
else
    success "sshd hardened — port ${SSH_PORT_NEW} + port 22 (still open for safety)."
fi

# -----------------------------------------------------------------------------
# 11. firewalld
# -----------------------------------------------------------------------------
info "Configuring firewalld..."
systemctl enable --now firewalld
ZONE="$(firewall-cmd --get-default-zone)"

if [[ "${LOCK_SSH:-0}" -eq 1 ]]; then
    firewall-cmd --zone="${ZONE}" --remove-service=ssh --permanent 2>/dev/null || true
else
    firewall-cmd --zone="${ZONE}" --add-service=ssh --permanent
fi

firewall-cmd --zone="${ZONE}" --add-port="${SSH_PORT_NEW}/tcp" --permanent
firewall-cmd --zone="${ZONE}" --add-service=http --permanent
firewall-cmd --zone="${ZONE}" --add-service=https --permanent
firewall-cmd --zone="${ZONE}" --add-port=443/udp --permanent
firewall-cmd --zone="${ZONE}" --add-service=smtp --permanent
firewall-cmd --zone="${ZONE}" --add-service=smtps --permanent
firewall-cmd --zone="${ZONE}" --add-port=587/tcp --permanent
firewall-cmd --zone="${ZONE}" --add-service=imaps --permanent
firewall-cmd --reload
success "firewalld configured (zone: ${ZONE})."

# -----------------------------------------------------------------------------
# 12. Test outbound mail
# -----------------------------------------------------------------------------
if [[ "${SMTP_RELAY}" != "none" ]]; then
    info "Sending test email to ${ADMIN_EMAIL}..."
    if {
        echo "From: ${MAIL_FROM_NAME} <${MAIL_FROM_ADDR}>"
        echo "To: ${ADMIN_EMAIL}"
        echo "Subject: [Alert on $(hostname -s)] serverdeploy 00-base complete"
        echo "Content-Type: text/plain; charset=UTF-8"
        echo
        echo "00-base.sh completed at $(date)."
        echo "Hostname    : ${SERVER_HOSTNAME}"
        echo "SSH ports   : $([[ ${LOCK_SSH:-0} -eq 1 ]] && echo "${SSH_PORT_NEW} (port 22 removed)" || echo "22 + ${SSH_PORT_NEW}")"
        echo "Relay       : ${SMTP_RELAY}"
        echo
        echo "If you got this, outbound mail works."
    } | sendmail -t; then
        success "Test email sent."
    else
        warn "Test email FAILED — investigate before relying on alerts."
        warn "  Logs: /var/log/serverdeploy/mail.log /var/log/msmtp.log"
        prompt CONTINUE_FAIL "Continue anyway? (y/N)" "n"
        [[ "${CONTINUE_FAIL,,}" =~ ^y ]] || die "Aborted — fix the relay and re-run."
    fi
fi

# -----------------------------------------------------------------------------
# Done
# -----------------------------------------------------------------------------
echo
success "00-base.sh complete."
if [[ "${LOCK_SSH:-0}" -ne 1 ]]; then
    warn ""
    warn "Port 22 is STILL OPEN. Verify ${SSH_PORT_NEW} works first:"
    warn "    ssh -p ${SSH_PORT_NEW} root@${SERVER_HOSTNAME}"
    warn ""
    warn "Then re-run with: ./bootstrap.sh 00-base.sh --lock-ssh"
fi
