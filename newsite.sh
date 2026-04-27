#!/bin/bash
# =============================================================================
# newsite.sh — provision a tenant site (Node / Next.js / PHP)
# Run as: root
#
# Single entry point. Asks for the type up front, then collects the rest.
# All sites share: per-domain Linux user, per-domain DB, per-domain logs/data,
# Caddy snippet with WAF + secure_headers, /etc/serverdeploy/sites/<domain>.meta.
#
# Node 2-port mode supports both API exposures:
#   subdir   — single Caddy site, /api/* → API port
#   subdomain — separate api.<domain> Caddy site, second cert
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for candidate in "/usr/local/lib/serverdeploy" "${SCRIPT_DIR}/lib"; do
    if [[ -f "${candidate}/common.sh" && -f "${candidate}/port-pool.sh" ]]; then
        # shellcheck disable=SC1090
        source "${candidate}/common.sh"
        # shellcheck disable=SC1090
        source "${candidate}/port-pool.sh"
        break
    fi
done
type port_pool_init >/dev/null 2>&1 || { echo "[ERROR] common.sh / port-pool.sh not found"; exit 1; }

require_root
load_config

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
SITES_ROOT="/srv/sites"
CADDY_SITES_DIR="/etc/caddy/sites"
CADDY_LOG_DIR="/var/log/caddy"
PHP_FPM_DIR="/etc/php-fpm.d"
PHP_FPM_SOCK_DIR="/run/php-fpm"
STATE_DIR="/etc/serverdeploy"
PORT_POOL_FILE="${STATE_DIR}/port-pool"
PORT_POOL_START=4000
PORT_POOL_END=5000
HOST_BIND="127.0.0.1"
TIMEZONE_VAL="${TIMEZONE:-UTC}"

mkdir -p "${STATE_DIR}/sites" "${SITES_ROOT}" "${CADDY_SITES_DIR}" "${CADDY_LOG_DIR}" "${PHP_FPM_SOCK_DIR}"
port_pool_init

# =============================================================================
# Type prompt
# =============================================================================
echo
info "=== New site ==="
info "  1) Node.js       (Express, Fastify, raw http, etc.)"
info "  2) Next.js       (single port, npx next start)"
info "  3) PHP / WordPress / Laravel"
echo
while :; do
    prompt SITE_KIND "Choice [1-3]"
    case "${SITE_KIND}" in 1|2|3) break ;; *) warn "Pick 1-3." ;; esac
done

case "${SITE_KIND}" in
    1) SITE_TYPE="node"; NODE_FLAVOR="generic" ;;
    2) SITE_TYPE="node"; NODE_FLAVOR="nextjs" ;;
    3) SITE_TYPE="php" ;;
esac

# =============================================================================
# Common prompts
# =============================================================================
echo
prompt DOMAIN "Domain (e.g. example.com)"
valid_domain "${DOMAIN}" || die "Invalid domain: ${DOMAIN}"
[[ -e "${SITES_ROOT}/${DOMAIN}" ]] && die "Site directory already exists."
[[ -e "${CADDY_SITES_DIR}/${DOMAIN}.caddy" ]] && die "Caddy config already exists."

prompt_yes_no ADD_WWW "Also serve www.${DOMAIN}?" "y"
WWW_DOMAIN=""
[[ "${ADD_WWW}" == "yes" ]] && WWW_DOMAIN="www.${DOMAIN}"

# Database
echo
if [[ "${SITE_TYPE}" == "php" ]]; then
    info "Database options: mariadb (WordPress default), postgres, none"
    prompt DB_TYPE "Database type" "mariadb"
else
    info "Database options: none, postgres, mariadb"
    prompt DB_TYPE "Database type" "none"
fi
DB_TYPE="${DB_TYPE,,}"
case "${DB_TYPE}" in none|postgres|mariadb) ;; *) die "Invalid DB type." ;; esac

# Node-specific
PORT_COUNT=1
API_MODE=""
if [[ "${SITE_TYPE}" == "node" ]]; then
    if [[ "${NODE_FLAVOR}" == "nextjs" ]]; then
        PORT_COUNT=1
    else
        echo
        info "Number of ports:"
        info "  1 = single process"
        info "  2 = backend + frontend"
        prompt PORT_COUNT "Number of ports" "1"
        [[ "${PORT_COUNT}" =~ ^[12]$ ]] || die "Port count must be 1 or 2."
        if [[ "${PORT_COUNT}" == "2" ]]; then
            echo
            info "API exposure:"
            info "  1) Subdirectory  https://${DOMAIN}/api/*"
            info "  2) Subdomain     https://api.${DOMAIN}/*"
            while :; do
                prompt API_CHOICE "Choice [1-2]" "1"
                case "${API_CHOICE}" in 1|2) break ;; *) warn "Pick 1-2." ;; esac
            done
            [[ "${API_CHOICE}" == "1" ]] && API_MODE="subdir" || API_MODE="subdomain"
        fi
    fi
fi

# =============================================================================
# Derived values
# =============================================================================
USERNAME="$(echo "${DOMAIN}" | tr '.' '-')"
[[ ${#USERNAME} -gt 32 ]] && USERNAME="${USERNAME:0:32}"

if [[ "${SITE_TYPE}" == "php" ]]; then
    DB_NAME="${USERNAME//-/_}"
    DB_USER="${USERNAME//-/_}"
else
    DB_NAME="${USERNAME}"
    DB_USER="${USERNAME}"
fi

SITE_DIR="${SITES_ROOT}/${DOMAIN}"

# Node layout
CODE_DIR="${SITE_DIR}/code"
DATA_DIR="${SITE_DIR}/data"
LOGS_DIR="${SITE_DIR}/logs"

# PHP layout
PUBLIC_DIR="${SITE_DIR}/public"
PRIVATE_DIR="${SITE_DIR}/private"
FPM_SOCK="${PHP_FPM_SOCK_DIR}/${USERNAME}.sock"
POOL_CONF="${PHP_FPM_DIR}/${USERNAME}.conf"

DOMAINS_FOR_DISPLAY="${DOMAIN}"
[[ -n "${WWW_DOMAIN}" ]] && DOMAINS_FOR_DISPLAY="${DOMAIN}, ${WWW_DOMAIN}"

# =============================================================================
# Pre-flight (no state changes yet)
# =============================================================================
id "${USERNAME}" >/dev/null 2>&1 && die "System user already exists: ${USERNAME}"

if [[ "${SITE_TYPE}" == "php" ]]; then
    command -v php-fpm >/dev/null 2>&1 || command -v /usr/sbin/php-fpm >/dev/null 2>&1 || \
        die "php-fpm not installed — run 30-runtimes.sh."
    getent passwd caddy >/dev/null || die "caddy user missing — run 10-caddy.sh."
    [[ -e "${POOL_CONF}" ]] && die "PHP-FPM pool already exists: ${POOL_CONF}"
fi

MYSQL_BIN=""
case "${DB_TYPE}" in
    postgres)
        command -v psql >/dev/null || die "psql not found — install PostgreSQL."
        sudo -u postgres psql -tAc "SELECT 1" >/dev/null 2>&1 || die "Cannot connect to postgres."
        EXISTS=$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" 2>/dev/null || true)
        [[ -z "${EXISTS}" ]] || die "Postgres DB already exists."
        EXISTS=$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" 2>/dev/null || true)
        [[ -z "${EXISTS}" ]] || die "Postgres role already exists."
        ;;
    mariadb)
        MYSQL_BIN="$(command -v mariadb || command -v mysql || true)"
        [[ -n "${MYSQL_BIN}" ]] || die "mariadb not found."
        ${MYSQL_BIN} -e "SELECT 1" >/dev/null 2>&1 || die "Cannot connect to MariaDB."
        EXISTS=$(${MYSQL_BIN} -N -B -e "SHOW DATABASES LIKE '${DB_NAME}'" 2>/dev/null || true)
        [[ -z "${EXISTS}" ]] || die "MariaDB DB already exists."
        ;;
esac

# Port preview
NEXT_PORT=""
PORTS_PREVIEW=""
if [[ "${SITE_TYPE}" == "node" ]]; then
    NEXT_PORT=$(port_pool_peek "${PORT_COUNT}") || die "No ${PORT_COUNT} consecutive free port(s)."
    if [[ "${PORT_COUNT}" == "1" ]]; then
        PORTS_PREVIEW="${NEXT_PORT}"
    else
        PORTS_PREVIEW="${NEXT_PORT} (api), $((NEXT_PORT + 1)) (ui)"
    fi
fi

# =============================================================================
# Confirmation
# =============================================================================
echo
info "About to create:"
echo "  Type        : ${SITE_TYPE}$([[ "${SITE_TYPE}" == "node" ]] && echo " (${NODE_FLAVOR})")"
echo "  Domain(s)   : ${DOMAINS_FOR_DISPLAY}"
echo "  System user : ${USERNAME}"
echo "  Site dir    : ${SITE_DIR}"
echo "  Database    : ${DB_TYPE}$([[ "${DB_TYPE}" != "none" ]] && echo "/${DB_NAME}")"
[[ -n "${PORTS_PREVIEW}" ]] && echo "  Port(s)     : ${PORTS_PREVIEW}"
[[ -n "${API_MODE}" ]] && echo "  API mode    : ${API_MODE}"
[[ "${SITE_TYPE}" == "php" ]] && echo "  PHP-FPM pool: ${POOL_CONF}"
echo
prompt CONFIRM "Proceed? (y/N)" "n"
[[ "${CONFIRM,,}" =~ ^y ]] || die "Aborted by user."

# =============================================================================
# Create system user
# =============================================================================
info "Creating system user ${USERNAME}..."
useradd --system --no-create-home --shell /usr/sbin/nologin "${USERNAME}"
USER_UID=$(id -u "${USERNAME}")
success "User '${USERNAME}' created (uid ${USER_UID})."

# =============================================================================
# Site directories
# =============================================================================
info "Creating site directories..."
if [[ "${SITE_TYPE}" == "node" ]]; then
    mkdir -p "${CODE_DIR}" "${DATA_DIR}" "${LOGS_DIR}"
    chown -R "${USERNAME}:${USERNAME}" "${SITE_DIR}"
    chmod 2770 "${SITE_DIR}"   # SGID + group-writable for siteuser.sh additions
else
    mkdir -p "${PUBLIC_DIR}" "${PRIVATE_DIR}" "${DATA_DIR}" "${DATA_DIR}/sessions" "${LOGS_DIR}"
    chown "${USERNAME}:${USERNAME}" "${SITE_DIR}"
    chmod 711 "${SITE_DIR}"
    chown -R "${USERNAME}:caddy" "${PUBLIC_DIR}"
    chmod 2750 "${PUBLIC_DIR}"
    chown -R "${USERNAME}:${USERNAME}" "${PRIVATE_DIR}" "${DATA_DIR}" "${LOGS_DIR}"
    chmod 700 "${PRIVATE_DIR}" "${DATA_DIR}" "${LOGS_DIR}" "${DATA_DIR}/sessions"

    if command -v semanage >/dev/null 2>&1 && getenforce 2>/dev/null | grep -q Enforcing; then
        if ! semanage fcontext -l 2>/dev/null | grep -qE "/srv/sites.*httpd_sys_rw_content_t"; then
            semanage fcontext -a -t httpd_sys_rw_content_t "/srv/sites(/.*)?" 2>/dev/null || true
        fi
        restorecon -R /srv/sites 2>/dev/null || true
    fi
fi
success "Directories ready at ${SITE_DIR}"

# =============================================================================
# Allocate ports (Node)
# =============================================================================
APP_PORT=""
API_PORT=""
UI_PORT=""
if [[ "${SITE_TYPE}" == "node" ]]; then
    info "Allocating ports..."
    PORT_BASE=$(port_pool_allocate "${PORT_COUNT}" "${USERNAME}") || die "Port allocation failed."
    if [[ "${PORT_COUNT}" == "1" ]]; then
        APP_PORT="${PORT_BASE}"
        success "Allocated port ${APP_PORT}"
    else
        API_PORT="${PORT_BASE}"
        UI_PORT="$((PORT_BASE + 1))"
        success "Allocated ports ${API_PORT} (api), ${UI_PORT} (ui)"
    fi
fi

# =============================================================================
# Database
# =============================================================================
DB_PASS=""
DB_URL=""
DB_DSN=""
case "${DB_TYPE}" in
    postgres)
        info "Creating Postgres DB + user..."
        DB_PASS=$(random_password 24)
        sudo -u postgres psql >/dev/null <<SQL
CREATE ROLE "${DB_USER}" LOGIN PASSWORD '${DB_PASS}'
    NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
CREATE DATABASE "${DB_NAME}" OWNER "${DB_USER}";
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT ALL ON DATABASE "${DB_NAME}" TO "${DB_USER}";
SQL
        DB_URL="postgres://${DB_USER}:${DB_PASS}@${HOST_BIND}:5432/${DB_NAME}"
        DB_DSN="pgsql:host=${HOST_BIND};dbname=${DB_NAME}"
        success "Postgres DB '${DB_NAME}' created."
        ;;
    mariadb)
        info "Creating MariaDB DB + user..."
        DB_PASS=$(random_password 24)
        ${MYSQL_BIN} <<SQL
CREATE DATABASE \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER '${DB_USER}'@'${HOST_BIND}' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'${HOST_BIND}';
REVOKE FILE, PROCESS, SUPER, RELOAD, SHUTDOWN ON *.* FROM '${DB_USER}'@'${HOST_BIND}';
FLUSH PRIVILEGES;
SQL
        DB_URL="mysql://${DB_USER}:${DB_PASS}@${HOST_BIND}:3306/${DB_NAME}"
        DB_DSN="mysql:host=${HOST_BIND};dbname=${DB_NAME};charset=utf8mb4"
        success "MariaDB DB '${DB_NAME}' created."
        ;;
esac

# =============================================================================
# Write Caddy + service config
# =============================================================================
DOMAINS_LINE="${DOMAIN}"
[[ -n "${WWW_DOMAIN}" ]] && DOMAINS_LINE="${DOMAIN}, ${WWW_DOMAIN}"

CADDY_FILE="${CADDY_SITES_DIR}/${DOMAIN}.caddy"
CADDY_API_FILE=""

if [[ "${SITE_TYPE}" == "node" ]]; then
    if [[ "${PORT_COUNT}" == "1" ]]; then
        cat > "${CADDY_FILE}" <<CADDY
${DOMAINS_LINE} {
    import waf
    import secure_headers
    import geoblock
    encode zstd gzip

    reverse_proxy ${HOST_BIND}:${APP_PORT}

    log {
        output file ${CADDY_LOG_DIR}/${DOMAIN}.log
    }
}
CADDY
    elif [[ "${API_MODE}" == "subdir" ]]; then
        cat > "${CADDY_FILE}" <<CADDY
${DOMAINS_LINE} {
    import waf
    import secure_headers
    import geoblock
    encode zstd gzip

    handle /api/* {
        reverse_proxy ${HOST_BIND}:${API_PORT}
    }

    handle {
        reverse_proxy ${HOST_BIND}:${UI_PORT}
    }

    log {
        output file ${CADDY_LOG_DIR}/${DOMAIN}.log
    }
}
CADDY
    else  # subdomain
        cat > "${CADDY_FILE}" <<CADDY
${DOMAINS_LINE} {
    import waf
    import secure_headers
    import geoblock
    encode zstd gzip

    reverse_proxy ${HOST_BIND}:${UI_PORT}

    log {
        output file ${CADDY_LOG_DIR}/${DOMAIN}.log
    }
}
CADDY
        CADDY_API_FILE="${CADDY_SITES_DIR}/api.${DOMAIN}.caddy"
        cat > "${CADDY_API_FILE}" <<CADDY
api.${DOMAIN} {
    import waf
    import secure_headers
    import geoblock
    encode zstd gzip

    reverse_proxy ${HOST_BIND}:${API_PORT}

    log {
        output file ${CADDY_LOG_DIR}/api.${DOMAIN}.log
    }
}
CADDY
        chown root:caddy "${CADDY_API_FILE}"
        chmod 640 "${CADDY_API_FILE}"
    fi
else
    # PHP-FPM pool
    cat > "${POOL_CONF}" <<POOL
; PHP-FPM pool for ${DOMAIN}
; Generated by newsite.sh on $(date -Iseconds)

[${USERNAME}]
user = ${USERNAME}
group = ${USERNAME}
listen = ${FPM_SOCK}
listen.owner = caddy
listen.group = caddy
listen.mode = 0660

pm = dynamic
pm.max_children = 8
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 4
pm.max_requests = 500

chdir = ${PUBLIC_DIR}
catch_workers_output = yes
decorate_workers_output = no

php_admin_value[error_log] = ${LOGS_DIR}/php-error.log
php_admin_flag[log_errors] = on
php_admin_value[memory_limit] = 512M
php_admin_value[upload_max_filesize] = 128M
php_admin_value[post_max_size] = 1024M
php_admin_value[max_execution_time] = 60
php_admin_value[max_input_time] = 60
php_admin_value[date.timezone] = ${TIMEZONE_VAL}
php_admin_flag[expose_php] = off
php_admin_flag[allow_url_fopen] = off
php_admin_flag[allow_url_include] = off
php_admin_value[disable_functions] = exec,passthru,shell_exec,system,proc_open,popen,pcntl_exec
php_admin_value[open_basedir] = ${SITE_DIR}/:/tmp/:/var/lib/php/
php_admin_value[session.save_path] = ${DATA_DIR}/sessions
php_admin_flag[session.cookie_secure] = on
php_admin_flag[session.cookie_httponly] = on
POOL
    chmod 644 "${POOL_CONF}"

    # Global UMask drop-in (idempotent)
    FPM_DROP_IN_DIR=/etc/systemd/system/php-fpm.service.d
    FPM_DROP_IN_FILE="${FPM_DROP_IN_DIR}/serverdeploy.conf"
    if [[ ! -f "${FPM_DROP_IN_FILE}" ]]; then
        mkdir -p "${FPM_DROP_IN_DIR}"
        printf '[Service]\nUMask=0027\n' > "${FPM_DROP_IN_FILE}"
        systemctl daemon-reload
    fi

    if systemctl is-active --quiet php-fpm; then
        systemctl restart php-fpm || die "php-fpm restart failed."
    else
        systemctl start php-fpm || die "php-fpm failed to start."
    fi
    sleep 1
    [[ -S "${FPM_SOCK}" ]] || die "FPM socket ${FPM_SOCK} not created."

    cat > "${CADDY_FILE}" <<CADDY
${DOMAINS_LINE} {
    import waf
    import secure_headers
    import geoblock
    encode zstd gzip

    root * ${PUBLIC_DIR}
    php_fastcgi unix/${FPM_SOCK}
    file_server

    log {
        output file ${CADDY_LOG_DIR}/${DOMAIN}.log
    }
}
CADDY
fi
chown root:caddy "${CADDY_FILE}"
chmod 640 "${CADDY_FILE}"
success "Caddy config → ${CADDY_FILE}"
[[ -n "${CADDY_API_FILE}" ]] && success "Caddy API config → ${CADDY_API_FILE}"

# =============================================================================
# Reload Caddy (validate first)
# =============================================================================
if /usr/local/bin/caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
    systemctl reload caddy && success "Caddy reloaded." || warn "Caddy reload failed."
else
    warn "Caddy validation failed — review the snippet."
fi

# =============================================================================
# systemd unit(s) for Node sites
# =============================================================================
SVC_NAMES=()
write_unit() {
    local unit_name="$1" port="$2" description="$3"
    local exec_default="/usr/bin/node index.js"
    [[ "${NODE_FLAVOR}" == "nextjs" ]] && exec_default="/usr/bin/npx next start -p ${port} -H ${HOST_BIND}"
    cat > "/etc/systemd/system/${unit_name}.service" <<UNIT
[Unit]
Description=${description}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${USERNAME}
Group=${USERNAME}
WorkingDirectory=${CODE_DIR}
EnvironmentFile=-${CODE_DIR}/.env
Environment=NODE_ENV=production
Environment=HOST=${HOST_BIND}
Environment=PORT=${port}
Environment=TZ=${TIMEZONE_VAL}

# TODO: edit ExecStart for your app's actual entry point.
ExecStart=${exec_default}

Restart=always
RestartSec=5
StandardOutput=append:${LOGS_DIR}/${unit_name}.log
StandardError=append:${LOGS_DIR}/${unit_name}.err

NoNewPrivileges=true
ProtectSystem=full
ReadWritePaths=${CODE_DIR} ${DATA_DIR} ${LOGS_DIR}
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
LockPersonality=true
MemoryMax=1G
TasksMax=256

[Install]
WantedBy=multi-user.target
UNIT
    chmod 644 "/etc/systemd/system/${unit_name}.service"
}

if [[ "${SITE_TYPE}" == "node" ]]; then
    if [[ "${PORT_COUNT}" == "1" ]]; then
        write_unit "${USERNAME}" "${APP_PORT}" "${DOMAIN} (Node app)"
        SVC_NAMES+=("${USERNAME}")
    else
        write_unit "${USERNAME}-api" "${API_PORT}" "${DOMAIN} (API backend)"
        write_unit "${USERNAME}-ui"  "${UI_PORT}"  "${DOMAIN} (UI frontend)"
        SVC_NAMES+=("${USERNAME}-api" "${USERNAME}-ui")
    fi
    systemctl daemon-reload
fi

# =============================================================================
# Metadata file
# =============================================================================
META_FILE="${STATE_DIR}/sites/${DOMAIN}.meta"
SYSTEMD_UNITS_STR="$(IFS=,; echo "${SVC_NAMES[*]}")"
{
    echo "DOMAIN=\"${DOMAIN}\""
    echo "WWW_DOMAIN=\"${WWW_DOMAIN}\""
    echo "USERNAME=\"${USERNAME}\""
    echo "SITE_DIR=\"${SITE_DIR}\""
    echo "DB_TYPE=\"${DB_TYPE}\""
    echo "DB_NAME=\"${DB_NAME}\""
    echo "DB_USER=\"${DB_USER}\""
    echo "SITE_TYPE=\"${SITE_TYPE}\""
    if [[ "${SITE_TYPE}" == "node" ]]; then
        echo "NODE_FLAVOR=\"${NODE_FLAVOR}\""
        echo "PORT_COUNT=\"${PORT_COUNT}\""
        echo "APP_PORT=\"${APP_PORT}\""
        echo "API_PORT=\"${API_PORT}\""
        echo "UI_PORT=\"${UI_PORT}\""
        echo "API_MODE=\"${API_MODE}\""
        echo "SYSTEMD_UNITS=\"${SYSTEMD_UNITS_STR}\""
    else
        echo "POOL_CONF=\"${POOL_CONF}\""
        echo "FPM_SOCK=\"${FPM_SOCK}\""
    fi
    echo "CADDY_FILE=\"${CADDY_FILE}\""
    echo "CADDY_API_FILE=\"${CADDY_API_FILE}\""
    echo "GEOIP_OVERRIDE=\"on\""
    echo "CREATED_AT=\"$(date -Iseconds)\""
} > "${META_FILE}"
chmod 600 "${META_FILE}"

# =============================================================================
# Summary
# =============================================================================
echo
echo "============================================================"
success "Site '${DOMAIN}' provisioned."
echo "============================================================"
echo
echo "  Type        : ${SITE_TYPE}$([[ "${SITE_TYPE}" == "node" ]] && echo " (${NODE_FLAVOR})")"
echo "  Domain(s)   : ${DOMAINS_FOR_DISPLAY}"
echo "  System user : ${USERNAME} (uid ${USER_UID})"
echo "  Site dir    : ${SITE_DIR}"
if [[ "${SITE_TYPE}" == "node" ]]; then
    if [[ "${PORT_COUNT}" == "1" ]]; then
        echo "  Port        : ${APP_PORT}"
    else
        echo "  API port    : ${API_PORT}"
        echo "  UI port     : ${UI_PORT}"
        echo "  API mode    : ${API_MODE}"
        [[ "${API_MODE}" == "subdomain" ]] && echo "  API URL     : https://api.${DOMAIN}/"
    fi
fi
if [[ "${DB_TYPE}" != "none" ]]; then
    echo
    echo "  Database    : ${DB_TYPE}/${DB_NAME}"
    echo "  DB user     : ${DB_USER}"
    echo "  DB password : ${DB_PASS}"
    [[ -n "${DB_URL}" ]] && echo "  DATABASE_URL: ${DB_URL}"
    [[ -n "${DB_DSN}" ]] && echo "  PHP DSN     : ${DB_DSN}"
fi
echo
echo "  Caddy config: ${CADDY_FILE}"
[[ -n "${CADDY_API_FILE}" ]] && echo "  Caddy (API) : ${CADDY_API_FILE}"
echo "  Metadata    : ${META_FILE}"
echo

if [[ "${SITE_TYPE}" == "node" ]]; then
    echo "Next steps:"
    echo "  1. Point DNS to this server."
    echo "  2. Drop code into ${CODE_DIR} (chown ${USERNAME}:${USERNAME})."
    echo "  3. Create ${CODE_DIR}/.env (mode 600, owned by ${USERNAME})."
    echo "  4. npm install / build as ${USERNAME}."
    echo "  5. Edit ExecStart in /etc/systemd/system/<svc>.service if needed."
    echo "  6. systemctl enable --now ${SVC_NAMES[*]}"
else
    echo "Next steps:"
    echo "  1. Point DNS to this server."
    echo "  2. Drop code into ${PUBLIC_DIR} as ${USERNAME}:caddy (mode 2750/640)."
    echo "  3. Visit https://${DOMAIN}/ to complete setup (WordPress/Laravel/etc.)."
fi
echo
[[ -n "${DB_PASS}" ]] && warn "DB password shown only once — save it."
echo

# =============================================================================
# Optional: mail domain
# =============================================================================
prompt_yes_no ADD_MAIL "Add mail domain for ${DOMAIN}?" "n"
if [[ "${ADD_MAIL}" == "yes" ]]; then
    SERVER_HOST="${SERVER_HOSTNAME:-$(hostname -f)}"
    STALWART_PASS=$(awk -F': ' '{print $2}' /etc/serverdeploy/stalwart-admin.txt 2>/dev/null || true)
    DKIM_SEL="${DKIM_SELECTOR:-default}"
    DKIM_PUBKEY=""

    if [[ -n "${STALWART_PASS}" ]]; then
        curl -sf -u "admin:${STALWART_PASS}" -X POST "http://127.0.0.1:8090/api/principal" \
            -H "Content-Type: application/json" \
            -d "{\"type\":\"domain\",\"name\":\"${DOMAIN}\"}" >/dev/null 2>&1 && \
            success "Domain added to Stalwart." || \
            warn "Could not add domain (may already exist)."
        curl -sf -u "admin:${STALWART_PASS}" -X POST "http://127.0.0.1:8090/api/dkim/${DOMAIN}" \
            -H "Content-Type: application/json" \
            -d "{\"domain\":\"${DOMAIN}\",\"selector\":\"${DKIM_SEL}\",\"algorithm\":\"Rsa\"}" >/dev/null 2>&1 && \
            success "DKIM key generated (selector: ${DKIM_SEL})." || \
            warn "Could not generate DKIM key (may already exist)."
        PRIVKEY=$(curl -sf -u "admin:${STALWART_PASS}" "http://127.0.0.1:8090/api/settings/group/signature" 2>/dev/null | \
            python3 -c "
import sys, json
data = json.load(sys.stdin).get('data', {}).get('items', [])
for item in data:
    if item.get('_id') == 'signature.rsa-${DOMAIN}.private-key':
        print(item.get('_value', ''))
" 2>/dev/null || true)
        if [[ -n "${PRIVKEY}" ]]; then
            DKIM_PUBKEY=$(echo "${PRIVKEY}" | openssl rsa -pubout 2>/dev/null | grep -v "^-" | tr -d '\n')
        fi
    else
        warn "Stalwart admin password not found — skipping API integration."
    fi

    echo
    info "Add these DNS records for ${DOMAIN}:"
    echo
    printf '  %-6s %-40s %s\n' "Type" "Name" "Value"
    printf '  %-6s %-40s %s\n' "----" "----" "-----"
    printf '  %-6s %-40s %s\n' "MX"   "${DOMAIN}" "10 ${SERVER_HOST}."
    printf '  %-6s %-40s %s\n' "TXT"  "${DOMAIN}" "v=spf1 a:${SERVER_HOST} -all"
    printf '  %-6s %-40s %s\n' "TXT"  "_dmarc.${DOMAIN}" "v=DMARC1; p=quarantine; rua=mailto:${ADMIN_EMAIL}"
    if [[ -n "${DKIM_PUBKEY}" ]]; then
        echo
        echo "  TXT    ${DKIM_SEL}._domainkey.${DOMAIN}"
        echo "         v=DKIM1; k=rsa; p=${DKIM_PUBKEY}"
    fi
    echo
    echo "MAIL_DOMAIN=\"yes\"" >> "${META_FILE}"
fi
