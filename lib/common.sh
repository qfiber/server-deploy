#!/bin/bash
# =============================================================================
# common.sh — shared helpers sourced by serverdeploy scripts
# =============================================================================

if [[ -n "${_COMMON_SH_LOADED:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi
_COMMON_SH_LOADED=1

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

require_root() {
    [[ $EUID -eq 0 ]] || die "Run as root."
}

prompt() {
    local var="$1" msg="$2" default="${3:-}"
    local input
    if [[ -n "${default}" ]]; then
        read -rp "${msg} [${default}]: " input
        input="${input:-${default}}"
    else
        read -rp "${msg}: " input
    fi
    printf -v "${var}" '%s' "${input}"
}

prompt_required() {
    local var="$1" msg="$2"
    local input=""
    while [[ -z "${input}" ]]; do
        read -rp "${msg}: " input
        [[ -z "${input}" ]] && warn "Value is required."
    done
    printf -v "${var}" '%s' "${input}"
}

prompt_yes_no() {
    local var="$1" msg="$2" default="${3:-y}"
    local input
    read -rp "${msg} [${default}]: " input
    input="${input:-${default}}"
    if [[ "${input,,}" =~ ^y ]]; then
        printf -v "${var}" '%s' "yes"
    else
        printf -v "${var}" '%s' "no"
    fi
}

prompt_secret() {
    local var="$1" msg="$2"
    local input
    read -rsp "${msg}: " input
    echo
    printf -v "${var}" '%s' "${input}"
}

# -----------------------------------------------------------------------------
# Validators
# -----------------------------------------------------------------------------
valid_domain() {
    [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$ ]]
}

valid_email() {
    [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

valid_port() {
    local p="$1"
    [[ "${p}" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 ))
}

valid_ipv4() {
    local ip="$1"
    [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS='.'
    local -a o=(${ip})
    (( o[0] <= 255 && o[1] <= 255 && o[2] <= 255 && o[3] <= 255 ))
}

valid_ipv4_cidr() {
    local cidr="$1"
    [[ "${cidr}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || return 1
    local mask="${cidr##*/}"
    (( mask >= 0 && mask <= 32 )) || return 1
    valid_ipv4 "${cidr%/*}"
}

valid_ipv6() {
    local ip="$1"
    # Loose but practical: hex groups separated by colons, optional :: shorthand,
    # optional zone id (which we strip first), optional embedded v4.
    [[ "${ip}" == *:* ]] || return 1
    [[ "${ip}" =~ ^[0-9A-Fa-f:.%]+$ ]] || return 1
    # Reject anything with > 8 colon-separated groups
    local IFS=':'
    local -a groups=(${ip})
    (( ${#groups[@]} <= 8 )) || return 1
    return 0
}

valid_ipv6_cidr() {
    local cidr="$1"
    [[ "${cidr}" == */* ]] || return 1
    local mask="${cidr##*/}"
    [[ "${mask}" =~ ^[0-9]+$ ]] || return 1
    (( mask >= 0 && mask <= 128 )) || return 1
    valid_ipv6 "${cidr%/*}"
}

valid_ip_or_cidr() {
    local v="$1"
    valid_ipv4 "${v}" || valid_ipv4_cidr "${v}" || valid_ipv6 "${v}" || valid_ipv6_cidr "${v}"
}

# -----------------------------------------------------------------------------
# Config IO
# -----------------------------------------------------------------------------
# Source /etc/serverdeploy/config and export every key=value pair
load_config() {
    local cfg="${SERVERDEPLOY_CONFIG:-/etc/serverdeploy/config}"
    [[ -f "${cfg}" ]] || return 0
    set -a
    # shellcheck disable=SC1090
    source "${cfg}"
    set +a
}

# Update a single KEY="VALUE" line in /etc/serverdeploy/config (in place).
# Adds the line if missing. Values must not contain double-quote characters.
config_set() {
    local key="$1" val="$2"
    local cfg="${SERVERDEPLOY_CONFIG:-/etc/serverdeploy/config}"
    [[ -f "${cfg}" ]] || die "config_set: ${cfg} does not exist"
    [[ "${val}" != *\"* ]] || die "config_set: value contains double-quote"
    local tmp="${cfg}.tmp.$$"
    if grep -qE "^${key}=" "${cfg}"; then
        awk -v k="${key}" -v v="${val}" '
            BEGIN { p="^"k"=" }
            $0 ~ p { print k"=\""v"\""; next }
            { print }
        ' "${cfg}" > "${tmp}"
    else
        cp "${cfg}" "${tmp}"
        printf '%s="%s"\n' "${key}" "${val}" >> "${tmp}"
    fi
    chmod --reference="${cfg}" "${tmp}"
    chown --reference="${cfg}" "${tmp}"
    mv "${tmp}" "${cfg}"
}

# -----------------------------------------------------------------------------
# Random + sysinfo
# -----------------------------------------------------------------------------
# Random hex password of given length (default 24)
random_password() {
    local len="${1:-24}"
    local half=$(( (len + 1) / 2 ))
    local raw
    raw=$(openssl rand -hex "${half}")
    printf '%s' "${raw:0:${len}}"
}

# Total RAM in MB
ram_mb() {
    awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo
}

# -----------------------------------------------------------------------------
# Public IP detection (NAT-aware)
# -----------------------------------------------------------------------------
# Echoes the detected public IPv4 + the source label, separated by a tab.
# Returns 1 if every method failed.
detect_public_ip() {
    local ip src
    for src in \
        "https://api.ipify.org|ipify" \
        "https://ifconfig.me/ip|ifconfig.me" \
        "https://icanhazip.com|icanhazip"; do
        local url="${src%%|*}" label="${src##*|}"
        ip="$(curl -fsS --max-time 3 "${url}" 2>/dev/null | tr -d '[:space:]')"
        if valid_ipv4 "${ip}"; then
            printf '%s\t%s\n' "${ip}" "${label}"
            return 0
        fi
    done
    # OpenDNS fallback
    if ip=$(dig +short +time=2 +tries=1 myip.opendns.com @resolver1.opendns.com 2>/dev/null); then
        ip="${ip//[[:space:]]/}"
        if valid_ipv4 "${ip}"; then
            printf '%s\t%s\n' "${ip}" "opendns"
            return 0
        fi
    fi
    # Local egress (only correct on non-NAT hosts)
    if ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'); then
        if valid_ipv4 "${ip}"; then
            printf '%s\t%s\n' "${ip}" "local-egress"
            return 0
        fi
    fi
    return 1
}

# Resolve A record for $1 against a public resolver (1.1.1.1).
# Echoes IP or empty.
resolve_a() {
    local host="$1" out
    out=$(dig +short +time=2 +tries=1 A "${host}" @1.1.1.1 2>/dev/null || true)
    printf '%s\n' "${out}" | grep -E '^[0-9]+\.' | head -1 || true
}

# -----------------------------------------------------------------------------
# Cooldown helper for monitoring/notify
# -----------------------------------------------------------------------------
# cooldown_should_fire <key> <cooldown_seconds>
# Returns 0 (fire) if either no prior fire OR last fire older than cooldown.
# Returns 1 (suppress) otherwise. Side-effect: on fire, writes the new ts.
cooldown_should_fire() {
    local key="$1" cooldown="${2:-900}"
    local dir=/var/lib/serverdeploy/alerts
    mkdir -p "${dir}"
    chmod 700 "${dir}"
    local f="${dir}/${key//\//_}.state"
    local now last
    now=$(date +%s)
    if [[ -f "${f}" ]]; then
        last=$(cat "${f}" 2>/dev/null || echo 0)
        if (( now - last < cooldown )); then
            return 1
        fi
    fi
    echo "${now}" > "${f}"
    return 0
}

# Clear a cooldown key (use when condition recovers, so the next firing
# isn't suppressed and a recovery notice can go out).
cooldown_clear() {
    local key="$1"
    local f="/var/lib/serverdeploy/alerts/${key//\//_}.state"
    rm -f "${f}"
}
