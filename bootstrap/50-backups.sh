#!/bin/bash
# =============================================================================
# 50-backups.sh — restic → Backblaze B2 + nightly cron + email on failure
#   - generates restic password if missing (/etc/serverdeploy/restic.password)
#   - installs /usr/local/bin/backup.sh (mariadb-dump + pg_dumpall + restic)
#   - cron daily at 03:00
#   - if B2 creds in /etc/serverdeploy/config are empty, the cron NOOPs
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${REPO_DIR}/lib/common.sh"

require_root
load_config

if [[ "${INSTALL_BACKUPS:-yes}" != "yes" ]]; then
    info "Backups not selected (INSTALL_BACKUPS=${INSTALL_BACKUPS:-no}) — skipping."
    # Tear down a previous install if the operator turned backups off
    rm -f /etc/cron.d/serverdeploy-backup /usr/local/bin/backup.sh
    exit 0
fi

RESTIC_PASSWORD_FILE=/etc/serverdeploy/restic.password
BACKUP_SCRIPT=/usr/local/bin/backup.sh

# -----------------------------------------------------------------------------
# 1. Generate restic password if missing
# -----------------------------------------------------------------------------
if [[ -f "${RESTIC_PASSWORD_FILE}" ]]; then
    info "Restic password already exists at ${RESTIC_PASSWORD_FILE}"
else
    info "Generating restic password..."
    random_password 48 > "${RESTIC_PASSWORD_FILE}"
    chmod 600 "${RESTIC_PASSWORD_FILE}"
    chown root:root "${RESTIC_PASSWORD_FILE}"
    success "Password generated → ${RESTIC_PASSWORD_FILE}"
    warn "BACK UP THIS PASSWORD SOMEWHERE OFFLINE."
    warn "Without it, the B2 archive cannot be restored."
fi

mkdir -p /var/lib/serverdeploy /var/log/serverdeploy /srv/backups/dumps

# -----------------------------------------------------------------------------
# Exclude list — operator-editable. Only seeded on first install; preserved
# on re-run so local tuning isn't clobbered.
# -----------------------------------------------------------------------------
EXCLUDE_FILE=/etc/serverdeploy/backup-excludes.txt
if [[ ! -f "${EXCLUDE_FILE}" ]]; then
    info "Writing default backup exclude list → ${EXCLUDE_FILE}"
    cat > "${EXCLUDE_FILE}" <<'EXCLUDES'
# /etc/serverdeploy/backup-excludes.txt
# One pattern per line — applied to restic via --exclude-file.
# Patterns match anywhere in the path (like .gitignore).
# After editing, the next nightly run picks it up.

# --- VCS / build artefacts ---
.git
node_modules
vendor/bin
.next/cache
.nuxt
.cache
.parcel-cache
.turbo
.svelte-kit
dist
build
coverage
.pytest_cache
__pycache__
*.pyc

# --- Editor / OS cruft ---
*.swp
*.swo
*~
.DS_Store
Thumbs.db
.idea
.vscode

# --- Runtime / transient ---
*.tmp
*.temp
*.log
*.pid
*.sock
.npm
.yarn/cache
.pnpm-store
.pm2
tmp
temp

# --- WordPress caches & plugin-generated backups ---
wp-content/cache
wp-content/w3tc-cache
wp-content/wp-rocket-cache
wp-content/et-cache
wp-content/litespeed
wp-content/ai1wm-backups
wp-content/backup-db
wp-content/backups
wp-content/backups-dup-pro
wp-content/updraft
wp-content/uploads/backupbuddy_backups
wp-content/uploads/cache
wp-content/wflogs

# --- Laravel / PHP frameworks ---
storage/logs
storage/framework/cache
storage/framework/sessions
storage/framework/views
bootstrap/cache

# --- Large binaries that belong elsewhere ---
*.iso
*.dmg
core
core.[0-9]*
EXCLUDES
    chmod 644 "${EXCLUDE_FILE}"
    chown root:root "${EXCLUDE_FILE}"
else
    info "Exclude list already exists — leaving in place."
fi

# -----------------------------------------------------------------------------
# 2. Write backup script
# -----------------------------------------------------------------------------
info "Writing ${BACKUP_SCRIPT}..."
cat > "${BACKUP_SCRIPT}" <<'BACKUP'
#!/bin/bash
# /usr/local/bin/backup.sh — nightly backup to Backblaze B2 via restic.
# - Dumps all MariaDB and Postgres databases to /srv/backups/dumps/
# - restic backup of /srv/sites + /srv/backups/dumps + /etc/serverdeploy + /etc/caddy/sites
# - restic forget --keep-daily 7 --keep-monthly 12 --prune
# - On failure, sends email via msmtp/Resend
# - If B2 creds missing in /etc/serverdeploy/config, exits 0 silently
set -euo pipefail

CONFIG=/etc/serverdeploy/config
PASSWORD_FILE=/etc/serverdeploy/restic.password
DUMP_DIR=/srv/backups/dumps
TIMESTAMP_FILE=/var/lib/serverdeploy/last-backup
LOG_FILE=/var/log/serverdeploy/backup.log

mkdir -p "${DUMP_DIR}" "$(dirname "${TIMESTAMP_FILE}")" "$(dirname "${LOG_FILE}")"

# shellcheck disable=SC1090
source "${CONFIG}"

if [[ -z "${B2_ACCOUNT_ID:-}" || -z "${B2_ACCOUNT_KEY:-}" || -z "${B2_BUCKET:-}" ]]; then
    echo "[$(date -Iseconds)] B2 credentials not configured — skipping backup." >> "${LOG_FILE}"
    exit 0
fi

export B2_ACCOUNT_ID B2_ACCOUNT_KEY
export RESTIC_REPOSITORY="b2:${B2_BUCKET}:serverdeploy"
export RESTIC_PASSWORD_FILE="${PASSWORD_FILE}"

DATE=$(date +%Y%m%d-%H%M%S)
ERR=""

err() {
    ERR="${ERR}${1}"$'\n'
    echo "[$(date -Iseconds)] ERROR: ${1}" >> "${LOG_FILE}"
}

mail_failure() {
    local body="$1"
    local subject="[$(hostname -s)] backup FAILED at $(date)"
    {
        echo "From: ${MAIL_FROM_NAME:-serverdeploy} <${MAIL_FROM_ADDR:-root@localhost}>"
        echo "To: ${ADMIN_EMAIL:-root}"
        echo "Subject: ${subject}"
        echo "Content-Type: text/plain; charset=UTF-8"
        echo
        echo "${body}"
        echo
        echo "Tail of ${LOG_FILE}:"
        tail -40 "${LOG_FILE}"
    } | msmtp -t || true
}

echo "[$(date -Iseconds)] === backup start ===" >> "${LOG_FILE}"

# Init repo if not yet initialized (suppresses error if it already exists)
if ! restic snapshots >/dev/null 2>&1; then
    echo "[$(date -Iseconds)] initializing restic repo..." >> "${LOG_FILE}"
    restic init >> "${LOG_FILE}" 2>&1 || err "restic init failed"
fi

# MariaDB dump
if systemctl is-active --quiet mariadb 2>/dev/null; then
    if mariadb-dump --all-databases --single-transaction --routines --triggers \
        2>>"${LOG_FILE}" | gzip > "${DUMP_DIR}/mariadb-${DATE}.sql.gz"; then
        echo "[$(date -Iseconds)] MariaDB dump OK" >> "${LOG_FILE}"
    else
        err "MariaDB dump failed"
    fi
fi

# Postgres dump
if systemctl is-active --quiet postgresql-16 2>/dev/null; then
    if sudo -u postgres pg_dumpall 2>>"${LOG_FILE}" | gzip > "${DUMP_DIR}/postgres-${DATE}.sql.gz"; then
        echo "[$(date -Iseconds)] Postgres dump OK" >> "${LOG_FILE}"
    else
        err "Postgres dump failed"
    fi
fi

# Restic backup
if restic backup \
        /srv/sites \
        /srv/backups/dumps \
        /etc/serverdeploy \
        /etc/caddy/sites \
        --exclude-file=/etc/serverdeploy/backup-excludes.txt \
        --exclude-caches \
        >> "${LOG_FILE}" 2>&1; then
    echo "[$(date -Iseconds)] restic backup OK" >> "${LOG_FILE}"
else
    err "restic backup failed"
fi

# Forget + prune
if restic forget \
        --keep-daily 7 --keep-monthly 12 \
        --prune >> "${LOG_FILE}" 2>&1; then
    echo "[$(date -Iseconds)] restic forget OK" >> "${LOG_FILE}"
else
    err "restic forget/prune failed"
fi

# Clean up local dumps older than 3 days (restic snapshots have them)
find "${DUMP_DIR}" -type f -name '*.sql.gz' -mtime +3 -delete 2>/dev/null || true

if [[ -n "${ERR}" ]]; then
    mail_failure "${ERR}"
    echo "[$(date -Iseconds)] === backup FAILED ===" >> "${LOG_FILE}"
    exit 1
fi

# Success — write timestamp for monitoring
date -Iseconds > "${TIMESTAMP_FILE}"
echo "[$(date -Iseconds)] === backup complete ===" >> "${LOG_FILE}"
exit 0
BACKUP
chmod 700 "${BACKUP_SCRIPT}"
chown root:root "${BACKUP_SCRIPT}"
success "Backup script installed → ${BACKUP_SCRIPT}"

# -----------------------------------------------------------------------------
# 3. Cron
# -----------------------------------------------------------------------------
cat > /etc/cron.d/serverdeploy-backup <<'EOF'
# serverdeploy nightly backup at 03:00
0 3 * * * root /usr/local/bin/backup.sh
EOF
chmod 644 /etc/cron.d/serverdeploy-backup
success "Cron installed (daily at 03:00)."

# -----------------------------------------------------------------------------
# Done
# -----------------------------------------------------------------------------
echo
success "50-backups.sh complete."
if [[ -z "${B2_ACCOUNT_ID:-}" ]]; then
    warn ""
    warn "B2 credentials NOT YET CONFIGURED in /etc/serverdeploy/config."
    warn "Backups will SILENTLY SKIP until you fill in:"
    warn "    B2_ACCOUNT_ID, B2_ACCOUNT_KEY, B2_BUCKET"
    warn "Then run a manual test: /usr/local/bin/backup.sh && tail /var/log/serverdeploy/backup.log"
fi
