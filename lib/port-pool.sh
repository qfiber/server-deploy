#!/bin/bash
# =============================================================================
# port-pool.sh — text-file backed port pool for serverdeploy
#
# State file format (one line per port):
#   <port> <status> <site> <allocated_at>
# where status is "free" or "used", and free entries use "-" placeholders.
#
# Sourced by newsite-node.sh and delsite-node.sh. Override the file path or
# range by exporting PORT_POOL_FILE / PORT_POOL_START / PORT_POOL_END before
# sourcing.
# =============================================================================

PORT_POOL_FILE="${PORT_POOL_FILE:-/etc/serverdeploy/port-pool}"
PORT_POOL_START="${PORT_POOL_START:-4000}"
PORT_POOL_END="${PORT_POOL_END:-5000}"

port_pool_init() {
    [[ -f "${PORT_POOL_FILE}" ]] && return 0
    mkdir -p "$(dirname "${PORT_POOL_FILE}")"
    local p
    {
        for ((p = PORT_POOL_START; p <= PORT_POOL_END; p++)); do
            printf '%d free - -\n' "${p}"
        done
    } > "${PORT_POOL_FILE}"
    chmod 600 "${PORT_POOL_FILE}"
}

_port_pool_lock() {
    exec 9>"${PORT_POOL_FILE}.lock"
    flock 9
}

_port_pool_unlock() {
    flock -u 9
    exec 9>&-
}

# Internal: scan for N consecutive free ports. Echo start port, or empty.
_port_pool_find_run() {
    local count="$1"
    awk -v need="${count}" '
        BEGIN { run = 0; start = 0 }
        $2 == "free" {
            if (run == 0) start = $1
            run++
            if (run == need) { print start; exit }
            next
        }
        { run = 0; start = 0 }
    ' "${PORT_POOL_FILE}"
}

# Find N consecutive free ports without committing. Echoes start port.
# Returns 1 if not enough consecutive free ports.
port_pool_peek() {
    local count="$1"
    local start
    start=$(_port_pool_find_run "${count}")
    [[ -z "${start}" ]] && return 1
    echo "${start}"
}

# Allocate N consecutive free ports for $site. Echoes start port.
# Returns 1 on failure.
port_pool_allocate() {
    local count="$1" site="$2"
    local now start end tmp
    now="$(date -Iseconds)"
    _port_pool_lock
    start=$(_port_pool_find_run "${count}")
    if [[ -z "${start}" ]]; then
        _port_pool_unlock
        echo "ERROR: no ${count} consecutive free ports in pool ${PORT_POOL_START}-${PORT_POOL_END}" >&2
        return 1
    fi
    end=$((start + count - 1))
    tmp="${PORT_POOL_FILE}.tmp"
    awk -v s="${start}" -v e="${end}" -v site="${site}" -v now="${now}" '
        $1 >= s && $1 <= e { print $1 " used " site " " now; next }
        { print }
    ' "${PORT_POOL_FILE}" > "${tmp}"
    mv "${tmp}" "${PORT_POOL_FILE}"
    chmod 600 "${PORT_POOL_FILE}"
    _port_pool_unlock
    echo "${start}"
}

# Mark all ports owned by $site as free.
port_pool_release() {
    local site="$1"
    local tmp
    _port_pool_lock
    tmp="${PORT_POOL_FILE}.tmp"
    awk -v site="${site}" '
        $2 == "used" && $3 == site { print $1 " free - -"; next }
        { print }
    ' "${PORT_POOL_FILE}" > "${tmp}"
    mv "${tmp}" "${PORT_POOL_FILE}"
    chmod 600 "${PORT_POOL_FILE}"
    _port_pool_unlock
}

# List ports owned by $site, space-separated.
port_pool_list_by_site() {
    local site="$1"
    awk -v site="${site}" '$2 == "used" && $3 == site { print $1 }' "${PORT_POOL_FILE}" | tr '\n' ' '
}

# Show pool stats: free count, used count, total.
port_pool_stats() {
    awk '
        $2 == "free" { f++ }
        $2 == "used" { u++ }
        END { printf "free=%d used=%d total=%d\n", f+0, u+0, NR }
    ' "${PORT_POOL_FILE}"
}
