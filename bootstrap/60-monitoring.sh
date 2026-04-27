#!/bin/bash
# =============================================================================
# 60-monitoring.sh — installs /usr/local/bin/health-check.sh and runs it on cron
#
# Coverage:
#   Disk %, inode %, RAM %, swap %, sustained CPU >85% for 5 min,
#   failed systemd units, cert expiry, backup age, restic key-list,
#   port-pool exhaustion, log volume, clock drift, site-reachability probe,
#   mail queue length, CrowdSec ban spike, dnf security updates pending.
#
# All alerts use cooldown_should_fire (15 min default). Subjects are
# "[Alert on <hostname>] <topic>" via lib/notify.sh.
# Cron: every minute (the script self-rate-limits via cooldowns).
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${REPO_DIR}/lib/common.sh"

require_root

HEALTH_SCRIPT=/usr/local/bin/health-check.sh

mkdir -p /var/lib/serverdeploy /var/log/serverdeploy /var/lib/serverdeploy/alerts /var/lib/serverdeploy/cpu
chmod 700 /var/lib/serverdeploy/alerts

info "Writing ${HEALTH_SCRIPT}..."
cat > "${HEALTH_SCRIPT}" <<'HEALTH'
#!/bin/bash
# /usr/local/bin/health-check.sh — runs every minute.
# Each check has its own cooldown; recovery emails are best-effort.
set -euo pipefail

# shellcheck disable=SC1091
source /usr/local/lib/serverdeploy/common.sh
# shellcheck disable=SC1091
source /usr/local/lib/serverdeploy/notify.sh
load_config

LOG=/var/log/serverdeploy/health.log
STATE=/var/lib/serverdeploy
mkdir -p "${STATE}/alerts" "${STATE}/cpu"

COOLDOWN="${ALERT_COOLDOWN:-900}"            # 15 min
CPU_THRESHOLD=85
CPU_SUSTAIN_SECONDS=300
RAM_THRESHOLD=90
SWAP_THRESHOLD=80
DISK_THRESHOLD=90
INODE_THRESHOLD=85
CERT_DAYS_THRESHOLD=14
BACKUP_AGE_HOURS=36
PORT_POOL_FREE_MIN=50
LOG_FILE_MAX_MB=500
VAR_LOG_MAX_GB=2
CLOCK_DRIFT_MAX=1
MAIL_QUEUE_MAX=50
CROWDSEC_SPIKE=100

# shellcheck disable=SC2034
ALL_GREEN=1

trip() {
    local key="$1" subject="$2" body="$3"
    send_alert "${key}" "${COOLDOWN}" "${subject}" "${body}" || true
    ALL_GREEN=0
    echo "[$(date -Iseconds)] FIRE ${key}: ${subject}" >> "${LOG}"
}

clear_state() {
    local key="$1" subject="$2"
    send_recovery "${key}" "${subject}" >/dev/null 2>&1 || true
}

# 1. Disk %
while IFS= read -r line; do
    pct=$(echo "${line}" | awk '{gsub("%","",$5); print $5}')
    mnt=$(echo "${line}" | awk '{print $6}')
    [[ -z "${pct}" ]] && continue
    if (( pct > DISK_THRESHOLD )); then
        trip "disk:${mnt}" "Disk ${mnt} at ${pct}%" "Threshold ${DISK_THRESHOLD}%."
    else
        clear_state "disk:${mnt}" "Disk ${mnt}"
    fi
done < <(df -hP / /srv 2>/dev/null | tail -n +2)

# 2. Inode %
while IFS= read -r line; do
    pct=$(echo "${line}" | awk '{gsub("%","",$5); print $5}')
    mnt=$(echo "${line}" | awk '{print $6}')
    [[ -z "${pct}" || ! "${pct}" =~ ^[0-9]+$ ]] && continue
    if (( pct > INODE_THRESHOLD )); then
        trip "inode:${mnt}" "Inodes ${mnt} at ${pct}%" "Threshold ${INODE_THRESHOLD}%."
    else
        clear_state "inode:${mnt}" "Inodes ${mnt}"
    fi
done < <(df -iP / /srv 2>/dev/null | tail -n +2)

# 3. RAM %
ram_used_pct=$(awk '/MemTotal:/{t=$2} /MemAvailable:/{a=$2} END{if(t>0) printf "%d", (1-a/t)*100}' /proc/meminfo)
if [[ -n "${ram_used_pct}" && ${ram_used_pct} -gt ${RAM_THRESHOLD} ]]; then
    trip "ram" "RAM at ${ram_used_pct}%" "Threshold ${RAM_THRESHOLD}%. $(free -h | head -3)"
else
    clear_state "ram" "RAM"
fi

# 4. Swap %
swap_total=$(awk '/SwapTotal/{print $2}' /proc/meminfo)
swap_free=$(awk '/SwapFree/{print $2}' /proc/meminfo)
if (( swap_total > 0 )); then
    swap_used_pct=$(( (swap_total - swap_free) * 100 / swap_total ))
    if (( swap_used_pct > SWAP_THRESHOLD )); then
        trip "swap" "Swap at ${swap_used_pct}%" "Threshold ${SWAP_THRESHOLD}%."
    else
        clear_state "swap" "Swap"
    fi
fi

# 5. Sustained CPU >85% for 5 min
cpu_now=$(awk '/^cpu /{idle=$5+$6; total=0; for(i=2;i<=NF;i++) total+=$i; print total" "idle}' /proc/stat)
prev_file="${STATE}/cpu/prev"
if [[ -f "${prev_file}" ]]; then
    prev=$(<"${prev_file}")
    p_total="${prev% *}"; p_idle="${prev#* }"
    c_total="${cpu_now% *}"; c_idle="${cpu_now#* }"
    dt=$((c_total - p_total)); di=$((c_idle - p_idle))
    if (( dt > 0 )); then
        cpu_pct=$(( (dt - di) * 100 / dt ))
        # Track sustained breach
        breach_file="${STATE}/cpu/breach"
        now=$(date +%s)
        if (( cpu_pct > CPU_THRESHOLD )); then
            if [[ ! -f "${breach_file}" ]]; then
                echo "${now}" > "${breach_file}"
            fi
            since=$(<"${breach_file}")
            if (( now - since >= CPU_SUSTAIN_SECONDS )); then
                trip "cpu" "CPU at ${cpu_pct}% sustained $(( (now - since) / 60 ))m" \
                    "Threshold ${CPU_THRESHOLD}% for ${CPU_SUSTAIN_SECONDS}s.

$(uptime)
Top processes:
$(ps -eo pid,user,%cpu,%mem,comm --sort=-%cpu | head -8)"
            fi
        else
            rm -f "${breach_file}"
            clear_state "cpu" "CPU"
        fi
    fi
fi
echo "${cpu_now}" > "${prev_file}"

# 6. Failed systemd units
mapfile -t failed < <(systemctl list-units --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | grep -v '^$')
if (( ${#failed[@]} > 0 )); then
    trip "systemd-failed" "${#failed[@]} failed systemd unit(s)" "Failed:
$(printf '  %s\n' "${failed[@]}")"
else
    clear_state "systemd-failed" "Systemd"
fi

# 7. Cert expiry
CERT_BASE=/var/lib/caddy/.local/share/caddy/certificates
if [[ -d "${CERT_BASE}" ]]; then
    while IFS= read -r crt; do
        domain=$(basename "$(dirname "${crt}")")
        expiry=$(openssl x509 -enddate -noout -in "${crt}" 2>/dev/null | cut -d= -f2)
        [[ -z "${expiry}" ]] && continue
        days_left=$(( ($(date -d "${expiry}" +%s) - $(date +%s)) / 86400 ))
        if (( days_left < CERT_DAYS_THRESHOLD )); then
            trip "cert:${domain}" "Cert ${domain} expires in ${days_left}d" "Threshold ${CERT_DAYS_THRESHOLD}d."
        else
            clear_state "cert:${domain}" "Cert ${domain}"
        fi
    done < <(find "${CERT_BASE}" -type f -name '*.crt' 2>/dev/null)
fi

# 8. Backup age
TS_FILE=/var/lib/serverdeploy/last-backup
if [[ -n "${B2_ACCOUNT_ID:-}" ]]; then
    if [[ -f "${TS_FILE}" ]]; then
        last_ts=$(date -d "$(cat "${TS_FILE}")" +%s 2>/dev/null || echo 0)
        age_hours=$(( ($(date +%s) - last_ts) / 3600 ))
        if (( age_hours > BACKUP_AGE_HOURS )); then
            trip "backup-age" "Last backup ${age_hours}h ago" "Threshold ${BACKUP_AGE_HOURS}h."
        else
            clear_state "backup-age" "Backup age"
        fi
    else
        trip "backup-missing" "No successful backup recorded" "B2 configured, ${TS_FILE} missing."
    fi

    # 9. restic key-list (catches password rotation/compromise)
    KEY_FILE=/etc/serverdeploy/restic.password
    if [[ -f "${KEY_FILE}" ]]; then
        export B2_ACCOUNT_ID B2_ACCOUNT_KEY
        export RESTIC_REPOSITORY="b2:${B2_BUCKET}:serverdeploy"
        export RESTIC_PASSWORD_FILE="${KEY_FILE}"
        # Cache the result to avoid hitting B2 every minute — refresh hourly
        cache="${STATE}/restic-keys.cache"
        if [[ ! -f "${cache}" ]] || (( $(date +%s) - $(date -r "${cache}" +%s 2>/dev/null || echo 0) > 3600 )); then
            if restic key list --no-lock 2>/dev/null > "${cache}.new"; then
                # Compare set of key IDs; alert if changed
                if [[ -f "${cache}" ]] && ! diff -q "${cache}" "${cache}.new" >/dev/null 2>&1; then
                    trip "restic-keys" "restic key list changed" \
                        "$(diff "${cache}" "${cache}.new" || true)"
                fi
                mv "${cache}.new" "${cache}"
            fi
        fi
    fi
fi

# 10. Port-pool exhaustion
POOL_FILE=/etc/serverdeploy/port-pool
if [[ -f "${POOL_FILE}" ]]; then
    free_count=$(awk '$2=="free"{c++} END{print c+0}' "${POOL_FILE}")
    if (( free_count < PORT_POOL_FREE_MIN )); then
        trip "port-pool" "Port pool low: ${free_count} free" "Threshold ${PORT_POOL_FREE_MIN}."
    else
        clear_state "port-pool" "Port pool"
    fi
fi

# 11. Log volume
var_log_mb=$(du -sm /var/log 2>/dev/null | awk '{print $1}')
if (( var_log_mb > VAR_LOG_MAX_GB * 1024 )); then
    trip "var-log-volume" "/var/log at ${var_log_mb}MB" "Threshold ${VAR_LOG_MAX_GB}GB."
else
    clear_state "var-log-volume" "/var/log volume"
fi
while IFS= read -r f; do
    [[ -z "${f}" ]] && continue
    sz_mb=$(du -m "${f}" 2>/dev/null | awk '{print $1}')
    if (( sz_mb > LOG_FILE_MAX_MB )); then
        trip "logfile:${f}" "Log ${f} at ${sz_mb}MB" "Threshold ${LOG_FILE_MAX_MB}MB."
    else
        clear_state "logfile:${f}" "Log ${f}"
    fi
done < <(find /var/log/caddy -maxdepth 1 -type f -name '*.log' 2>/dev/null)

# 12. Clock drift
if command -v chronyc >/dev/null 2>&1; then
    drift=$(chronyc tracking 2>/dev/null | awk '/Last offset/{print $4}' | tr -d -)
    if [[ -n "${drift}" ]]; then
        # Compare via awk (drift is float)
        if awk -v d="${drift}" -v m="${CLOCK_DRIFT_MAX}" 'BEGIN{exit !(d > m)}'; then
            trip "clock" "Clock drift ${drift}s" "Threshold ${CLOCK_DRIFT_MAX}s."
        else
            clear_state "clock" "Clock"
        fi
    fi
fi

# 13. Site reachability probe (every metafile → curl on 127.0.0.1 with Host)
if [[ -d /etc/serverdeploy/sites ]]; then
    for meta in /etc/serverdeploy/sites/*.meta; do
        [[ -f "${meta}" ]] || continue
        DOMAIN="" SITE_TYPE=""
        # shellcheck disable=SC1090
        source "${meta}"
        [[ -z "${DOMAIN}" ]] && continue
        code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 \
                    --resolve "${DOMAIN}:443:127.0.0.1" "https://${DOMAIN}/" 2>/dev/null || echo 000)
        if [[ "${code}" == "000" || "${code}" =~ ^5[0-9]{2}$ ]]; then
            trip "reach:${DOMAIN}" "Site ${DOMAIN} returned ${code}" \
                "curl https://${DOMAIN}/ via 127.0.0.1 returned ${code}."
        else
            clear_state "reach:${DOMAIN}" "Site ${DOMAIN}"
        fi
    done
fi

# 14. CrowdSec ban spike
if command -v cscli >/dev/null 2>&1; then
    bans=$(cscli decisions list -o json 2>/dev/null | jq 'length' 2>/dev/null || echo 0)
    if [[ "${bans}" =~ ^[0-9]+$ ]] && (( bans > CROWDSEC_SPIKE )); then
        trip "crowdsec-spike" "CrowdSec ${bans} active decisions" "Threshold ${CROWDSEC_SPIKE}."
    fi
fi

# 15. dnf security updates pending (informational, lower frequency via own cooldown)
if [[ -x /usr/bin/dnf ]]; then
    pending=$(dnf -q updateinfo list security 2>/dev/null | wc -l)
    if (( pending > 0 )); then
        # 24h cooldown on this one
        if cooldown_should_fire "dnf-security" 86400; then
            send_email "${pending} pending security update(s)" \
                "$(dnf -q updateinfo list security 2>&1 | head -40)" || true
        fi
    fi
fi

# 17. GeoIP mmdb age (only when GeoIP is on)
if [[ "${GEOIP_ENABLED:-no}" == "yes" ]]; then
    MMDB=/var/lib/GeoIP/GeoLite2-Country.mmdb
    if [[ ! -f "${MMDB}" ]]; then
        trip "geoip-missing" "GeoIP mmdb missing" "Expected at ${MMDB}."
    else
        age_days=$(( ($(date +%s) - $(stat -c %Y "${MMDB}")) / 86400 ))
        if (( age_days > 14 )); then
            trip "geoip-stale" "GeoIP mmdb is ${age_days}d old" \
                "Threshold 14d. Refresh via geoipupdate or new offline files."
        else
            clear_state "geoip-stale" "GeoIP mmdb"
        fi
    fi
fi

# 16. Mail queue (Stalwart)
if systemctl is-active --quiet stalwart 2>/dev/null; then
    qcount=$(find /opt/stalwart/data/queue -type f 2>/dev/null | wc -l)
    if (( qcount > MAIL_QUEUE_MAX )); then
        trip "mail-queue" "Stalwart queue ${qcount} messages" "Threshold ${MAIL_QUEUE_MAX}."
    else
        clear_state "mail-queue" "Mail queue"
    fi
fi

echo "[$(date -Iseconds)] check complete (green=${ALL_GREEN})" >> "${LOG}"
exit 0
HEALTH
chmod 755 "${HEALTH_SCRIPT}"
chown root:root "${HEALTH_SCRIPT}"
success "Health check installed → ${HEALTH_SCRIPT}"

# -----------------------------------------------------------------------------
# Cron — every minute (script self-rate-limits via cooldowns)
# -----------------------------------------------------------------------------
cat > /etc/cron.d/serverdeploy-health <<'EOF'
* * * * * root /usr/local/bin/health-check.sh
EOF
chmod 644 /etc/cron.d/serverdeploy-health
success "Cron installed (every minute)."

info "Running health check once for validation..."
if "${HEALTH_SCRIPT}"; then
    success "Health check ran cleanly."
else
    warn "Health check returned non-zero — check ${HEALTH_SCRIPT} output above."
fi

success "60-monitoring.sh complete."
