#!/bin/bash
# =============================================================================
# delsite.sh — Remove a tenant site (Node or PHP) provisioned by newsite-*.sh
# Run as: root
#
# Usage:
#   delsite.sh                  # interactive: numbered list, pick by number
#   delsite.sh example.com      # non-interactive domain selection
#
# Reads SITE_TYPE from /etc/serverdeploy/sites/<domain>.meta and handles
# both Node (systemd units, port pool) and PHP (FPM pool, restart php-fpm).
#
# Archives ALL configs + site dir into a single tar.gz before deleting:
#   - /srv/sites/<domain>/           (site files)
#   - systemd unit(s)                (if node)
#   - Caddy site snippet
#   - PHP-FPM pool config            (if php)
#   - metadata file
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Library loading
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for candidate in \
    "/usr/local/lib/serverdeploy" \
    "${SCRIPT_DIR}/lib"; do
    if [[ -f "${candidate}/common.sh" && -f "${candidate}/port-pool.sh" ]]; then
        # shellcheck disable=SC1090
        source "${candidate}/common.sh"
        # shellcheck disable=SC1090
        source "${candidate}/port-pool.sh"
        break
    fi
done
type port_pool_release >/dev/null 2>&1 || { echo "[ERROR] common.sh / port-pool.sh not found"; exit 1; }

require_root

STATE_DIR="/etc/serverdeploy"
SITES_META_DIR="${STATE_DIR}/sites"
BACKUP_DIR="/srv/backups/archived"
PORT_POOL_FILE="${STATE_DIR}/port-pool"
HOST_BIND="127.0.0.1"

# -----------------------------------------------------------------------------
# Resolve target domain — numbered list, select by number
# -----------------------------------------------------------------------------
DOMAIN="${1:-}"
if [[ -z "${DOMAIN}" ]]; then
    mapfile -t SITE_LIST < <(ls -1 "${SITES_META_DIR}"/*.meta 2>/dev/null | sed 's|.*/||; s|\.meta$||' | sort)
    if [[ ${#SITE_LIST[@]} -eq 0 ]]; then
        die "No provisioned sites found in ${SITES_META_DIR}/"
    fi
    echo
    info "Provisioned sites:"
    for i in "${!SITE_LIST[@]}"; do
        # Show site type from meta if available
        local_type=""
        if grep -q 'SITE_TYPE=' "${SITES_META_DIR}/${SITE_LIST[$i]}.meta" 2>/dev/null; then
            local_type=$(grep 'SITE_TYPE=' "${SITES_META_DIR}/${SITE_LIST[$i]}.meta" | head -1 | cut -d'"' -f2)
        fi
        echo "  $((i + 1))) ${SITE_LIST[$i]}${local_type:+ [${local_type}]}"
    done
    echo
    prompt PICK "Select site number to delete"
    [[ "${PICK}" =~ ^[0-9]+$ ]] || die "Enter a number."
    idx=$((PICK - 1))
    [[ ${idx} -ge 0 && ${idx} -lt ${#SITE_LIST[@]} ]] || die "Number out of range."
    DOMAIN="${SITE_LIST[$idx]}"
fi

META_FILE="${SITES_META_DIR}/${DOMAIN}.meta"
[[ -f "${META_FILE}" ]] || die "No metadata found for '${DOMAIN}' at ${META_FILE}. Manual cleanup required."

# Initialize all expected fields so set -u doesn't bite if meta is partial
DOMAIN=""
WWW_DOMAIN=""
USERNAME=""
SITE_DIR=""
DB_TYPE="none"
DB_NAME=""
DB_USER=""
PORT_COUNT=""
APP_PORT=""
API_PORT=""
UI_PORT=""
CADDY_FILE=""
CADDY_API_FILE=""
API_MODE=""
NODE_FLAVOR=""
SYSTEMD_UNITS=""
POOL_CONF=""
FPM_SOCK=""
SITE_TYPE=""
MAIL_DOMAIN=""
CREATED_AT=""

# shellcheck disable=SC1090
source "${META_FILE}"

# -----------------------------------------------------------------------------
# Confirmation
# -----------------------------------------------------------------------------
echo
warn "About to PERMANENTLY DELETE:"
echo "  Domain        : ${DOMAIN}${WWW_DOMAIN:+ (and ${WWW_DOMAIN})}"
echo "  Type          : ${SITE_TYPE:-unknown}"
echo "  System user   : ${USERNAME}"
echo "  Site dir      : ${SITE_DIR}"
if [[ "${DB_TYPE}" != "none" && -n "${DB_TYPE}" ]]; then
    echo "  Database      : ${DB_TYPE}/${DB_NAME}"
    echo "  DB user       : ${DB_USER}"
fi
[[ -n "${CADDY_FILE}" ]] && echo "  Caddy config  : ${CADDY_FILE}"
[[ -n "${SYSTEMD_UNITS}" ]] && echo "  Systemd units : ${SYSTEMD_UNITS}"
[[ -n "${POOL_CONF}" ]] && echo "  FPM pool      : ${POOL_CONF}"
if [[ -n "${APP_PORT}" ]]; then
    echo "  Port(s)       : ${APP_PORT}"
elif [[ -n "${API_PORT}" ]]; then
    echo "  Port(s)       : ${API_PORT}, ${UI_PORT}"
fi
echo
echo "  All configs + site files will be archived before deletion."
echo
prompt CONFIRM "Type the domain '${DOMAIN}' to confirm"
[[ "${CONFIRM}" == "${DOMAIN}" ]] || die "Confirmation does not match. Aborted."

# -----------------------------------------------------------------------------
# 1. Archive EVERYTHING into a single tar.gz before touching anything
# -----------------------------------------------------------------------------
info "Archiving site + all configs..."
mkdir -p "${BACKUP_DIR}"
chmod 700 "${BACKUP_DIR}"
TS=$(date +%Y%m%d-%H%M%S)
ARCHIVE="${BACKUP_DIR}/${DOMAIN}-${TS}.tar.gz"

# Stage configs into a temp dir alongside the site dir
STAGE_DIR=$(mktemp -d)
CONFIGS_DIR="${STAGE_DIR}/configs"
mkdir -p "${CONFIGS_DIR}"

# Copy all config files to staging (if they exist)
[[ -n "${CADDY_FILE}" && -f "${CADDY_FILE}" ]] && cp "${CADDY_FILE}" "${CONFIGS_DIR}/"
[[ -n "${POOL_CONF}" && -f "${POOL_CONF}" ]] && cp "${POOL_CONF}" "${CONFIGS_DIR}/"
[[ -f "${META_FILE}" ]] && cp "${META_FILE}" "${CONFIGS_DIR}/"
if [[ -n "${SYSTEMD_UNITS}" ]]; then
    IFS=',' read -ra UNITS_LIST <<< "${SYSTEMD_UNITS}"
    for unit in "${UNITS_LIST[@]}"; do
        [[ -z "${unit}" ]] && continue
        [[ -f "/etc/systemd/system/${unit}.service" ]] && cp "/etc/systemd/system/${unit}.service" "${CONFIGS_DIR}/"
    done
fi

# Build the tar: configs dir + site dir (if it exists)
TAR_ARGS=("-czf" "${ARCHIVE}" "-C" "${STAGE_DIR}" "configs")
if [[ -n "${SITE_DIR}" && -d "${SITE_DIR}" ]]; then
    TAR_ARGS+=("-C" "$(dirname "${SITE_DIR}")" "$(basename "${SITE_DIR}")")
fi
tar "${TAR_ARGS[@]}"
chmod 600 "${ARCHIVE}"
rm -rf "${STAGE_DIR}"
success "Archived to ${ARCHIVE}"

# -----------------------------------------------------------------------------
# 2. Stop & remove systemd units (Node sites)
# -----------------------------------------------------------------------------
if [[ -n "${SYSTEMD_UNITS}" ]]; then
    info "Stopping and removing systemd units..."
    IFS=',' read -ra UNITS <<< "${SYSTEMD_UNITS}"
    for unit in "${UNITS[@]}"; do
        [[ -z "${unit}" ]] && continue
        systemctl disable --now "${unit}.service" 2>/dev/null || true
        rm -f "/etc/systemd/system/${unit}.service"
    done
    systemctl daemon-reload
    success "Systemd units removed."
fi

# -----------------------------------------------------------------------------
# 3. Remove PHP-FPM pool config (PHP sites)
# -----------------------------------------------------------------------------
if [[ -n "${POOL_CONF}" && -f "${POOL_CONF}" ]]; then
    info "Removing PHP-FPM pool config..."
    rm -f "${POOL_CONF}"
    # Restart php-fpm so it drops the pool workers (also fixes userdel later)
    if systemctl is-active --quiet php-fpm; then
        systemctl restart php-fpm 2>/dev/null || warn "php-fpm restart failed."
    fi
    success "FPM pool removed."
fi

# -----------------------------------------------------------------------------
# 4. Remove Caddy config(s) + per-site coraza file and reload
# -----------------------------------------------------------------------------
if [[ -n "${CADDY_FILE}" && -f "${CADDY_FILE}" ]]; then
    info "Removing Caddy config..."
    rm -f "${CADDY_FILE}"
fi
if [[ -n "${CADDY_API_FILE}" && -f "${CADDY_API_FILE}" ]]; then
    rm -f "${CADDY_API_FILE}"
fi
rm -f "/etc/caddy/coraza/sites/${DOMAIN}.conf"
if systemctl reload caddy 2>/dev/null; then
    success "Caddy reloaded."
else
    warn "Caddy reload failed."
fi

# 4b. Remove site users (siteuser.sh additions)
USERS_FILE="${SITES_META_DIR}/${DOMAIN}.users"
if [[ -f "${USERS_FILE}" ]]; then
    info "Removing site users..."
    while IFS=':' read -r u _mode _added; do
        [[ -z "${u}" ]] && continue
        rm -f "/etc/ssh/sshd_config.d/50-siteuser-${u}.conf"
        rm -f "/etc/sudoers.d/serverdeploy-${u}"
        if id "${u}" >/dev/null 2>&1; then
            pkill -u "${u}" 2>/dev/null || true
            sleep 0.3
            userdel -r "${u}" 2>/dev/null || userdel "${u}" 2>/dev/null || true
        fi
    done < "${USERS_FILE}"
    rm -f "${USERS_FILE}"
    sshd -t 2>/dev/null && systemctl reload sshd 2>/dev/null || warn "sshd reload skipped."
fi

# -----------------------------------------------------------------------------
# 5. Drop database
# -----------------------------------------------------------------------------
case "${DB_TYPE}" in
    postgres)
        info "Dropping Postgres database and user..."
        if command -v psql >/dev/null && sudo -u postgres psql -tAc "SELECT 1" >/dev/null 2>&1; then
            sudo -u postgres psql >/dev/null <<SQL
DROP DATABASE IF EXISTS "${DB_NAME}";
DROP USER IF EXISTS "${DB_USER}";
SQL
            success "Postgres database dropped."
        else
            warn "Postgres unreachable — drop ${DB_NAME}/${DB_USER} manually."
        fi
        ;;
    mariadb)
        info "Dropping MariaDB database and user..."
        MYSQL_BIN="$(command -v mariadb || command -v mysql || true)"
        if [[ -n "${MYSQL_BIN}" ]] && ${MYSQL_BIN} -e "SELECT 1" >/dev/null 2>&1; then
            ${MYSQL_BIN} <<SQL
DROP DATABASE IF EXISTS \`${DB_NAME}\`;
DROP USER IF EXISTS '${DB_USER}'@'${HOST_BIND}';
DROP USER IF EXISTS '${DB_USER}'@'%';
FLUSH PRIVILEGES;
SQL
            success "MariaDB database dropped."
        else
            warn "MariaDB unreachable — drop ${DB_NAME}/${DB_USER} manually."
        fi
        ;;
    none|"")
        ;;
esac

# -----------------------------------------------------------------------------
# 6. Remove site directory
# -----------------------------------------------------------------------------
if [[ -n "${SITE_DIR}" && -d "${SITE_DIR}" ]]; then
    info "Removing site directory..."
    rm -rf "${SITE_DIR}"
    success "Site directory removed."
fi

# -----------------------------------------------------------------------------
# 7. Kill tenant processes and remove system user
# -----------------------------------------------------------------------------
if [[ -n "${USERNAME}" ]] && id "${USERNAME}" >/dev/null 2>&1; then
    # Kill any remaining processes (php-fpm workers, node, etc.) so userdel succeeds
    pkill -u "${USERNAME}" 2>/dev/null || true
    sleep 0.5
    pkill -9 -u "${USERNAME}" 2>/dev/null || true
    sleep 0.3
    info "Removing system user ${USERNAME}..."
    if userdel "${USERNAME}" 2>/dev/null; then
        success "User removed."
    else
        warn "userdel failed — check 'ps -u ${USERNAME}' for lingering processes."
    fi
fi

# -----------------------------------------------------------------------------
# 8. Release ports back to the pool (Node sites)
# -----------------------------------------------------------------------------
if [[ -n "${USERNAME}" ]] && [[ -f "${PORT_POOL_FILE}" ]]; then
    RELEASED=$(port_pool_list_by_site "${USERNAME}")
    if [[ -n "${RELEASED}" ]]; then
        info "Releasing port(s) back to pool: ${RELEASED}"
        port_pool_release "${USERNAME}"
        success "Ports released."
    fi
fi

# -----------------------------------------------------------------------------
# 9. Remove metadata file
# -----------------------------------------------------------------------------
rm -f "${META_FILE}"

# -----------------------------------------------------------------------------
# Clean up old archives (older than 7 days)
# -----------------------------------------------------------------------------
OLD_ARCHIVES=$(find "${BACKUP_DIR}" -type f -name '*.tar.gz' -mtime +7 2>/dev/null | wc -l)
if [[ ${OLD_ARCHIVES} -gt 0 ]]; then
    info "Cleaning ${OLD_ARCHIVES} archive(s) older than 7 days..."
    find "${BACKUP_DIR}" -type f -name '*.tar.gz' -mtime +7 -delete 2>/dev/null
    success "Old archives cleaned."
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo
echo "============================================================"
success "Site '${DOMAIN}' removed."
echo "============================================================"
echo
echo "  Archive : ${ARCHIVE} (retained for 7 days)"
echo "  Contains: site files + Caddy snippet + systemd units + FPM pool + metadata"
echo
if [[ "${MAIL_DOMAIN}" == "yes" ]]; then
    STALWART_PASS=$(awk -F': ' '{print $2}' /etc/serverdeploy/stalwart-admin.txt 2>/dev/null || true)
    if [[ -n "${STALWART_PASS}" ]]; then
        info "Removing mail domain '${DOMAIN}' from Stalwart..."
        # Delete DKIM signature
        curl -sf -u "admin:${STALWART_PASS}" -X DELETE \
            "http://127.0.0.1:8090/api/settings/group/signature.rsa-${DOMAIN}" >/dev/null 2>&1 || true
        # Delete domain principal
        curl -sf -u "admin:${STALWART_PASS}" -X DELETE \
            "http://127.0.0.1:8090/api/principal/${DOMAIN}" >/dev/null 2>&1 && \
            success "Mail domain removed from Stalwart." || \
            warn "Could not remove mail domain from Stalwart — remove manually."
    else
        warn "Stalwart admin password not found."
    fi
    warn "Remember to also remove DNS records (MX, SPF, DKIM, DMARC) for ${DOMAIN}."
    echo
fi
