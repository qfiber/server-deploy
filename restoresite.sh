#!/bin/bash
# =============================================================================
# restoresite.sh — restore a site from /srv/backups/archived/<domain>-<ts>.tar.gz
# Run as: root
#
# The archive holds:
#   configs/   — Caddy snippet, FPM pool (PHP), systemd units (Node), meta file
#   <SITE_DIR>/ — full site tree
#
# Restore flow:
#   1. Pick archive (numbered list, or pass <archive-path>).
#   2. Extract to a tmp dir.
#   3. Parse meta to recreate user, dirs (with original perms), DB + DB user.
#   4. Re-import latest matching DB dump if found in /srv/backups/dumps/.
#   5. Drop configs back in place (Caddy, FPM, systemd, meta).
#   6. Reload Caddy + restart php-fpm; daemon-reload + start systemd units.
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
type require_root >/dev/null 2>&1 || { echo "[ERROR] common.sh / port-pool.sh not found"; exit 1; }
require_root

ARCHIVE_DIR=/srv/backups/archived
DUMPS_DIR=/srv/backups/dumps
STATE_DIR=/etc/serverdeploy
HOST_BIND=127.0.0.1

ARCHIVE="${1:-}"
if [[ -z "${ARCHIVE}" ]]; then
    mapfile -t LIST < <(ls -1t "${ARCHIVE_DIR}"/*.tar.gz 2>/dev/null)
    [[ ${#LIST[@]} -gt 0 ]] || die "No archives in ${ARCHIVE_DIR}"
    echo
    info "Available archives:"
    for i in "${!LIST[@]}"; do
        printf '  %d) %s\n' "$((i + 1))" "$(basename "${LIST[$i]}")"
    done
    echo
    prompt PICK "Number"
    [[ "${PICK}" =~ ^[0-9]+$ ]] || die "Not a number."
    idx=$((PICK - 1))
    [[ ${idx} -ge 0 && ${idx} -lt ${#LIST[@]} ]] || die "Out of range."
    ARCHIVE="${LIST[$idx]}"
fi
[[ -f "${ARCHIVE}" ]] || die "Archive not found: ${ARCHIVE}"
info "Archive: ${ARCHIVE}"

# Extract
TMP=$(mktemp -d)
trap 'rm -rf "${TMP}"' EXIT
tar -xzf "${ARCHIVE}" -C "${TMP}"

# Locate meta
META=$(find "${TMP}/configs" -maxdepth 1 -name '*.meta' | head -1)
[[ -f "${META}" ]] || die "No metadata in archive."
DOMAIN="" WWW_DOMAIN="" USERNAME="" SITE_DIR="" DB_TYPE="none" DB_NAME="" DB_USER=""
SITE_TYPE="" CADDY_FILE="" CADDY_API_FILE="" POOL_CONF="" SYSTEMD_UNITS=""
APP_PORT="" API_PORT="" UI_PORT="" PORT_COUNT=""
# shellcheck disable=SC1090
source "${META}"
[[ -n "${DOMAIN}" && -n "${USERNAME}" ]] || die "meta missing core fields."

# Confirm
echo
warn "About to RESTORE:"
echo "  Domain     : ${DOMAIN}"
echo "  Type       : ${SITE_TYPE}"
echo "  System user: ${USERNAME}"
echo "  Site dir   : ${SITE_DIR}"
echo "  Database   : ${DB_TYPE}/${DB_NAME}"
echo
[[ -e "${SITE_DIR}" ]] && warn "Existing ${SITE_DIR} will be OVERWRITTEN."
id "${USERNAME}" >/dev/null 2>&1 && warn "User ${USERNAME} already exists — will reuse."
prompt CONFIRM "Type the domain '${DOMAIN}' to confirm"
[[ "${CONFIRM}" == "${DOMAIN}" ]] || die "Aborted."

# 1. User
if ! id "${USERNAME}" >/dev/null 2>&1; then
    info "Creating system user ${USERNAME}..."
    useradd --system --no-create-home --shell /usr/sbin/nologin "${USERNAME}"
fi

# 2. Site directory
info "Restoring site files..."
rm -rf "${SITE_DIR}"
mkdir -p "$(dirname "${SITE_DIR}")"
mv "${TMP}/$(basename "${SITE_DIR}")" "${SITE_DIR}"
# Re-apply baseline ownership; tar preserved permissions inside
chown -R "${USERNAME}:${USERNAME}" "${SITE_DIR}"
if [[ "${SITE_TYPE}" == "php" ]]; then
    chown -R "${USERNAME}:caddy" "${SITE_DIR}/public" 2>/dev/null || true
    find "${SITE_DIR}/public" -type d -exec chmod 2750 {} + 2>/dev/null || true
fi

# 3. Database
case "${DB_TYPE}" in
    postgres)
        info "Recreating Postgres DB + user..."
        DB_PASS=$(random_password 24)
        sudo -u postgres psql >/dev/null <<SQL
DROP DATABASE IF EXISTS "${DB_NAME}";
DROP ROLE IF EXISTS "${DB_USER}";
CREATE ROLE "${DB_USER}" LOGIN PASSWORD '${DB_PASS}'
    NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
CREATE DATABASE "${DB_NAME}" OWNER "${DB_USER}";
SQL
        # Try to import from latest pg_dumpall
        latest=$(ls -1t "${DUMPS_DIR}"/postgres-*.sql.gz 2>/dev/null | head -1 || true)
        if [[ -n "${latest}" ]]; then
            info "Importing from ${latest} (filtering DB ${DB_NAME})..."
            zcat "${latest}" | sudo -u postgres psql -v ON_ERROR_STOP=0 "${DB_NAME}" >/dev/null 2>&1 || \
                warn "Postgres import returned non-zero — review manually."
        else
            warn "No Postgres dump in ${DUMPS_DIR} — DB is empty."
        fi
        ;;
    mariadb)
        info "Recreating MariaDB DB + user..."
        DB_PASS=$(random_password 24)
        MYSQL_BIN="$(command -v mariadb || command -v mysql)"
        ${MYSQL_BIN} <<SQL
DROP DATABASE IF EXISTS \`${DB_NAME}\`;
CREATE DATABASE \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
DROP USER IF EXISTS '${DB_USER}'@'${HOST_BIND}';
CREATE USER '${DB_USER}'@'${HOST_BIND}' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'${HOST_BIND}';
REVOKE FILE, PROCESS, SUPER, RELOAD, SHUTDOWN ON *.* FROM '${DB_USER}'@'${HOST_BIND}';
FLUSH PRIVILEGES;
SQL
        latest=$(ls -1t "${DUMPS_DIR}"/mariadb-*.sql.gz 2>/dev/null | head -1 || true)
        if [[ -n "${latest}" ]]; then
            info "Importing ${DB_NAME} from ${latest}..."
            zcat "${latest}" | ${MYSQL_BIN} "${DB_NAME}" 2>/dev/null || \
                warn "MariaDB import returned non-zero — review manually."
        else
            warn "No MariaDB dump in ${DUMPS_DIR} — DB is empty."
        fi
        ;;
esac

# 4. Restore configs
info "Restoring configs..."
[[ -n "${CADDY_FILE}" ]]     && cp "${TMP}/configs/$(basename "${CADDY_FILE}")"     "${CADDY_FILE}"     2>/dev/null || true
[[ -n "${CADDY_API_FILE}" ]] && cp "${TMP}/configs/$(basename "${CADDY_API_FILE}")" "${CADDY_API_FILE}" 2>/dev/null || true
[[ -n "${POOL_CONF}" ]]      && cp "${TMP}/configs/$(basename "${POOL_CONF}")"      "${POOL_CONF}"      2>/dev/null || true
if [[ -n "${SYSTEMD_UNITS}" ]]; then
    IFS=',' read -ra units <<< "${SYSTEMD_UNITS}"
    for u in "${units[@]}"; do
        [[ -z "${u}" ]] && continue
        cp "${TMP}/configs/${u}.service" "/etc/systemd/system/${u}.service" 2>/dev/null || true
    done
    systemctl daemon-reload
fi
cp "${META}" "${STATE_DIR}/sites/$(basename "${META}")"
chmod 600 "${STATE_DIR}/sites/$(basename "${META}")"
[[ -f "${POOL_CONF}" ]] && chmod 644 "${POOL_CONF}"
[[ -f "${CADDY_FILE}" ]] && { chown root:caddy "${CADDY_FILE}"; chmod 640 "${CADDY_FILE}"; }
[[ -f "${CADDY_API_FILE}" ]] && { chown root:caddy "${CADDY_API_FILE}"; chmod 640 "${CADDY_API_FILE}"; }

# 5. Reallocate ports if Node
if [[ "${SITE_TYPE}" == "node" ]]; then
    port_pool_init
    if [[ "${PORT_COUNT}" == "1" && -n "${APP_PORT}" ]]; then
        # Best-effort: mark the original port "used" for this site
        warn "Note: original port allocation was ${APP_PORT}. Adjust port-pool manually if needed."
    elif [[ -n "${API_PORT}" ]]; then
        warn "Note: original ports ${API_PORT}/${UI_PORT}. Adjust port-pool manually if needed."
    fi
fi

# 6. Reload services
if [[ -n "${POOL_CONF}" ]]; then
    systemctl restart php-fpm 2>/dev/null || warn "php-fpm restart failed."
fi
if /usr/local/bin/caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
    systemctl reload caddy && success "Caddy reloaded." || warn "Caddy reload failed."
else
    warn "Caddyfile validation failed — review manually."
fi
if [[ -n "${SYSTEMD_UNITS}" ]]; then
    IFS=',' read -ra units <<< "${SYSTEMD_UNITS}"
    for u in "${units[@]}"; do
        [[ -z "${u}" ]] && continue
        systemctl enable "${u}.service" 2>/dev/null || true
        systemctl restart "${u}.service" 2>/dev/null || warn "${u} restart failed."
    done
fi

echo
success "Site '${DOMAIN}' restored."
[[ -n "${DB_PASS:-}" ]] && {
    echo
    warn "New DB password: ${DB_PASS}"
    warn "Update ${SITE_DIR}/code/.env (Node) or wp-config.php (PHP)."
}
