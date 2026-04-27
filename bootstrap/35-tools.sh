#!/bin/bash
# =============================================================================
# 35-tools.sh — phpMyAdmin + pgAdmin4 (only if selected at install time)
#
# Both run under dedicated unprivileged users, behind the admin guard
# (IP allowlist + HTTP basic auth + rate limit + WAF).
# Caddy admin sites are written under /etc/caddy/sites/_pma.caddy and _pga.caddy.
#
# Toggle via INSTALL_PMA / INSTALL_PGA in /etc/serverdeploy/config (set at install).
# Re-running this stage after a config change adds/removes tooling.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${REPO_DIR}/lib/common.sh"

require_root
load_config

INSTALL_PMA="${INSTALL_PMA:-no}"
INSTALL_PGA="${INSTALL_PGA:-no}"

if [[ "${INSTALL_PMA}" != "yes" && "${INSTALL_PGA}" != "yes" ]]; then
    info "Neither phpMyAdmin nor pgAdmin4 selected — skipping."
    exit 0
fi

[[ -n "${MAIL_ADMIN_ALLOWLIST:-}" ]] || die "MAIL_ADMIN_ALLOWLIST not set."

CADDY_SITES=/etc/caddy/sites
mkdir -p "${CADDY_SITES}"

# -----------------------------------------------------------------------------
# Helper: write a Caddy admin-guarded site
#   $1 = host  $2 = upstream  $3 = basic-auth user  $4 = bcrypt hash
#   $5 = optional pre-handler block (e.g. "root * /usr/share/phpMyAdmin")
#   $6 = handler ("reverse_proxy 127.0.0.1:5050" / "php_fastcgi unix//run/php-fpm/pma.sock\n            file_server")
# -----------------------------------------------------------------------------
write_admin_site() {
    local host="$1" basic_user="$2" basic_hash="$3" extra_root="$4" handler="$5"
    local file="${CADDY_SITES}/_$(echo "${host}" | tr . _).caddy"
    cat > "${file}" <<CADDY
${host} {
    import waf
    import secure_headers
    import geoblock
    encode zstd gzip

    @allowed remote_ip ${MAIL_ADMIN_ALLOWLIST}

    rate_limit {
        zone ${host//./_}_zone {
            key {client_ip}
            events 30
            window 1m
        }
    }

    handle @allowed {
        basic_auth {
            ${basic_user} ${basic_hash}
        }
        ${extra_root}
        ${handler}
    }

    handle {
        abort
    }

    log {
        output file /var/log/caddy/${host}.log
    }
}
CADDY
    chown root:caddy "${file}"
    chmod 640 "${file}"
}

# -----------------------------------------------------------------------------
# phpMyAdmin
# -----------------------------------------------------------------------------
if [[ "${INSTALL_PMA}" == "yes" ]]; then
    [[ -n "${PMA_HOST:-}" ]] || die "PMA_HOST not set."
    info "=== phpMyAdmin ==="

    command -v php-fpm >/dev/null 2>&1 || die "php-fpm not installed (run 30-runtimes.sh first)."
    rpm -q phpMyAdmin >/dev/null 2>&1 || dnf -y install phpMyAdmin
    success "phpMyAdmin package present."

    # Dedicated user
    if ! id pma >/dev/null 2>&1; then
        useradd --system --no-create-home --shell /usr/sbin/nologin --comment "phpMyAdmin runner" pma
    fi
    mkdir -p /var/lib/phpMyAdmin/sessions /var/log/phpMyAdmin
    chown -R pma:pma /var/lib/phpMyAdmin /var/log/phpMyAdmin
    chmod 700 /var/lib/phpMyAdmin /var/lib/phpMyAdmin/sessions

    # Dedicated FPM pool
    cat > /etc/php-fpm.d/pma.conf <<'POOL'
[pma]
user = pma
group = pma
listen = /run/php-fpm/pma.sock
listen.owner = caddy
listen.group = caddy
listen.mode = 0660

pm = ondemand
pm.max_children = 4
pm.process_idle_timeout = 30s
pm.max_requests = 200

chdir = /usr/share/phpMyAdmin
catch_workers_output = yes
decorate_workers_output = no

php_admin_value[error_log] = /var/log/phpMyAdmin/php-error.log
php_admin_flag[log_errors] = on
php_admin_value[memory_limit] = 256M
php_admin_value[upload_max_filesize] = 64M
php_admin_value[post_max_size] = 64M
php_admin_value[max_execution_time] = 60
php_admin_flag[expose_php] = off
php_admin_flag[allow_url_fopen] = off
php_admin_flag[allow_url_include] = off
php_admin_value[disable_functions] = exec,passthru,shell_exec,system,proc_open,popen,curl_exec,curl_multi_exec,parse_ini_file,show_source,pcntl_exec
php_admin_value[open_basedir] = /usr/share/phpMyAdmin/:/etc/phpMyAdmin/:/var/lib/phpMyAdmin/:/var/log/phpMyAdmin/:/tmp/:/var/lib/php/
php_admin_value[session.save_path] = /var/lib/phpMyAdmin/sessions
php_admin_flag[session.cookie_secure] = on
php_admin_flag[session.cookie_httponly] = on
POOL
    chmod 644 /etc/php-fpm.d/pma.conf

    # Blowfish secret for phpMyAdmin (persisted to config)
    if [[ -z "${PMA_BLOWFISH:-}" ]]; then
        PMA_BLOWFISH=$(random_password 32)
        config_set PMA_BLOWFISH "${PMA_BLOWFISH}"
    fi

    # phpMyAdmin config — cookie auth, no stored creds
    PMA_CFG=/etc/phpMyAdmin/config.inc.php
    cat > "${PMA_CFG}" <<PHPCFG
<?php
\$cfg['blowfish_secret'] = '${PMA_BLOWFISH}';
\$i = 0;
\$i++;
\$cfg['Servers'][\$i]['host'] = '127.0.0.1';
\$cfg['Servers'][\$i]['port'] = '3306';
\$cfg['Servers'][\$i]['auth_type'] = 'cookie';
\$cfg['Servers'][\$i]['AllowNoPassword'] = false;
\$cfg['Servers'][\$i]['AllowRoot'] = false;
\$cfg['LoginCookieValidity'] = 1800;
\$cfg['LoginCookieRecall'] = false;
\$cfg['ShowServerInfo'] = false;
\$cfg['ShowDbStructureCreation'] = false;
\$cfg['SaveDir'] = '';
\$cfg['UploadDir'] = '';
\$cfg['VersionCheck'] = false;
\$cfg['CaptchaApi'] = '';
\$cfg['SendErrorReports'] = 'never';
PHPCFG
    chown root:pma "${PMA_CFG}"
    chmod 640 "${PMA_CFG}"

    # Basic auth password
    PMA_AUTH_FILE=/etc/serverdeploy/pma-basic-auth.txt
    if [[ ! -f "${PMA_AUTH_FILE}" ]]; then
        PMA_BASIC_PASS=$(random_password 24)
        # Caddy uses bcrypt; generate via the binary's `caddy hash-password`
        PMA_HASH=$(/usr/local/bin/caddy hash-password --plaintext "${PMA_BASIC_PASS}")
        printf 'user: admin\npassword: %s\nbcrypt: %s\n' "${PMA_BASIC_PASS}" "${PMA_HASH}" > "${PMA_AUTH_FILE}"
        chmod 600 "${PMA_AUTH_FILE}"
        success "phpMyAdmin basic auth → ${PMA_AUTH_FILE}"
    fi
    PMA_HASH=$(awk '/^bcrypt:/ {sub(/^bcrypt: /,""); print}' "${PMA_AUTH_FILE}")

    # Restart php-fpm to pick up the pool
    systemctl restart php-fpm
    sleep 1

    write_admin_site "${PMA_HOST}" "admin" "${PMA_HASH}" \
        "root * /usr/share/phpMyAdmin" \
        "php_fastcgi unix//run/php-fpm/pma.sock
        file_server"
    success "Caddy site written for ${PMA_HOST}."
fi

# -----------------------------------------------------------------------------
# pgAdmin4
# -----------------------------------------------------------------------------
if [[ "${INSTALL_PGA}" == "yes" ]]; then
    [[ -n "${PGA_HOST:-}" ]] || die "PGA_HOST not set."
    info "=== pgAdmin4 ==="

    # PGDG repo (postgresql 16 + pgadmin4)
    if ! rpm -q pgadmin4-web >/dev/null 2>&1; then
        if ! rpm -q pgdg-redhat-repo >/dev/null 2>&1; then
            dnf -y install "https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm"
        fi
        # pgadmin4-web depends on python3-mod_wsgi (Apache) — we install it then
        # ignore Apache. We run gunicorn directly under systemd.
        dnf -y install pgadmin4-web python3-gunicorn
    fi

    # Dedicated user
    if ! id pgadmin >/dev/null 2>&1; then
        useradd --system --shell /usr/sbin/nologin --home-dir /var/lib/pgadmin --create-home pgadmin
    fi
    mkdir -p /var/lib/pgadmin /var/log/pgadmin
    chown -R pgadmin:pgadmin /var/lib/pgadmin /var/log/pgadmin
    chmod 750 /var/lib/pgadmin /var/log/pgadmin

    # Locate pgAdmin4 module dir (varies by Python version)
    PGA_DIR=$(rpm -ql pgadmin4-web 2>/dev/null | grep -m1 '/pgadmin4/config_distro.py$' | xargs dirname 2>/dev/null || true)
    [[ -d "${PGA_DIR}" ]] || PGA_DIR="/usr/lib/python3.9/site-packages/pgadmin4-web"
    [[ -d "${PGA_DIR}" ]] || die "Cannot locate pgadmin4-web module dir."

    # config_local.py — server mode, sane defaults
    cat > "${PGA_DIR}/config_local.py" <<PYCFG
SERVER_MODE = True
DATA_DIR = '/var/lib/pgadmin'
LOG_FILE = '/var/log/pgadmin/pgadmin4.log'
SESSION_DB_PATH = '/var/lib/pgadmin/sessions'
SQLITE_PATH = '/var/lib/pgadmin/pgadmin4.db'
STORAGE_DIR = '/var/lib/pgadmin/storage'
DEFAULT_BINARY_PATHS = {'pg': '/usr/pgsql-16/bin'}
MASTER_PASSWORD_REQUIRED = True
MAX_LOGIN_ATTEMPTS = 5
LOGIN_BANNER = "Authorized access only."
SESSION_COOKIE_SECURE = True
SESSION_COOKIE_HTTPONLY = True
SESSION_COOKIE_SAMESITE = 'Strict'
ENHANCED_COOKIE_PROTECTION = True
PYCFG
    chown root:pgadmin "${PGA_DIR}/config_local.py"
    chmod 640 "${PGA_DIR}/config_local.py"

    # Initial admin email/password
    PGA_AUTH_FILE=/etc/serverdeploy/pgadmin-admin.txt
    if [[ ! -f "${PGA_AUTH_FILE}" ]]; then
        PGA_PASS=$(random_password 24)
        printf 'email: %s\npassword: %s\n' "${ADMIN_EMAIL}" "${PGA_PASS}" > "${PGA_AUTH_FILE}"
        chmod 600 "${PGA_AUTH_FILE}"
        # Run pgAdmin's setup.py as pgadmin to seed the DB with this user
        sudo -u pgadmin PGADMIN_SETUP_EMAIL="${ADMIN_EMAIL}" PGADMIN_SETUP_PASSWORD="${PGA_PASS}" \
            python3 "${PGA_DIR}/setup.py" 2>/dev/null || warn "pgAdmin setup.py reported errors (often benign on re-run)."
        success "pgAdmin4 admin → ${PGA_AUTH_FILE}"
    fi

    # Basic auth in front of pgAdmin (defence in depth)
    PGA_BASIC_FILE=/etc/serverdeploy/pgadmin-basic-auth.txt
    if [[ ! -f "${PGA_BASIC_FILE}" ]]; then
        PGA_BASIC_PASS=$(random_password 24)
        PGA_HASH=$(/usr/local/bin/caddy hash-password --plaintext "${PGA_BASIC_PASS}")
        printf 'user: admin\npassword: %s\nbcrypt: %s\n' "${PGA_BASIC_PASS}" "${PGA_HASH}" > "${PGA_BASIC_FILE}"
        chmod 600 "${PGA_BASIC_FILE}"
    fi
    PGA_HASH=$(awk '/^bcrypt:/ {sub(/^bcrypt: /,""); print}' "${PGA_BASIC_FILE}")

    # systemd unit — gunicorn on 127.0.0.1:5050 as pgadmin
    cat > /etc/systemd/system/pgadmin4.service <<UNIT
[Unit]
Description=pgAdmin 4 (gunicorn)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=pgadmin
Group=pgadmin
WorkingDirectory=${PGA_DIR}
Environment=PYTHONPATH=${PGA_DIR}
ExecStart=/usr/bin/gunicorn --workers=2 --threads=4 --bind=127.0.0.1:5050 --timeout=180 pgAdmin4:app
Restart=always
RestartSec=5
StandardOutput=append:/var/log/pgadmin/gunicorn.log
StandardError=append:/var/log/pgadmin/gunicorn.err

NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
LockPersonality=true
ReadWritePaths=/var/lib/pgadmin /var/log/pgadmin
MemoryMax=512M

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable --now pgadmin4
    sleep 2
    systemctl is-active --quiet pgadmin4 || warn "pgadmin4 not active — journalctl -u pgadmin4 -n 50"

    write_admin_site "${PGA_HOST}" "admin" "${PGA_HASH}" \
        "" \
        "reverse_proxy 127.0.0.1:5050"
    success "Caddy site written for ${PGA_HOST}."
fi

# -----------------------------------------------------------------------------
# Reload Caddy
# -----------------------------------------------------------------------------
if /usr/local/bin/caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
    systemctl reload caddy && success "Caddy reloaded." || warn "Caddy reload failed."
else
    die "Caddyfile failed validation. Check /etc/caddy/sites/_*.caddy"
fi

echo
success "35-tools.sh complete."
[[ "${INSTALL_PMA}" == "yes" ]] && info "  phpMyAdmin → https://${PMA_HOST}/  (creds: /etc/serverdeploy/pma-basic-auth.txt)"
[[ "${INSTALL_PGA}" == "yes" ]] && info "  pgAdmin4   → https://${PGA_HOST}/  (creds: /etc/serverdeploy/pgadmin-admin.txt + pgadmin-basic-auth.txt)"
