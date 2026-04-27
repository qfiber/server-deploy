#!/bin/bash
# =============================================================================
# geoblock.sh — manage GeoIP country block + per-IP bypass + per-site override
# Run as: root
#
# Sources of truth in /etc/serverdeploy/config:
#   GEOIP_ENABLED, GEOIP_MODE, GEOIP_COUNTRIES, GEOIP_BYPASS_IPS
#
# Usage:
#   geoblock status                    show current settings
#   geoblock countries set RU,CN,KP    replace the country list
#   geoblock countries add IR
#   geoblock countries remove RU
#   geoblock countries list
#
#   geoblock bypass add  <ip|cidr>     IP/CIDR that escapes the block
#   geoblock bypass remove [<ip|cidr>] no arg → numbered prompt
#   geoblock bypass list
#
#   geoblock disable <domain>          per-site: skip 'import geoblock'
#   geoblock enable  <domain>
#
#   geoblock mode block|allow          block = default-allow + deny list
#                                       allow = default-deny + allow list
#
# Each change rewrites /etc/caddy/snippets/geoblock.caddy + the CrowdSec
# scenario, validates with `caddy validate`, then reloads. Rolls back on fail.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for candidate in "/usr/local/lib/serverdeploy" "${SCRIPT_DIR}/lib"; do
    [[ -f "${candidate}/common.sh" ]] && { source "${candidate}/common.sh"; break; }
done
type require_root >/dev/null 2>&1 || { echo "[ERROR] common.sh not found"; exit 1; }
require_root

CONFIG=/etc/serverdeploy/config
CADDY=/usr/local/bin/caddy
CADDYFILE=/etc/caddy/Caddyfile
SNIPPET=/etc/caddy/snippets/geoblock.caddy
SCENARIO=/etc/crowdsec/scenarios/serverdeploy-geoblock.yaml
SITES_META=/etc/serverdeploy/sites
LOG=/var/log/serverdeploy/geoblock.log
mkdir -p "$(dirname "${LOG}")" /etc/caddy/snippets

[[ -f "${CONFIG}" ]] || die "Config not found: ${CONFIG}"

audit() {
    {
        echo "[$(date -Iseconds)] actor=${SUDO_USER:-${USER}} $*"
    } >> "${LOG}"
}

# Render the Caddy snippet from current GEOIP_* vars
render_snippet() {
    load_config
    local mmdb=/var/lib/GeoIP/GeoLite2-Country.mmdb
    if [[ "${GEOIP_ENABLED:-no}" != "yes" || ! -f "${mmdb}" ]]; then
        cat > "${SNIPPET}" <<'GB'
(geoblock) {
    # GeoIP disabled. No-op.
}
GB
        return 0
    fi

    local countries_lower=""
    IFS=',' read -ra carr <<<"${GEOIP_COUNTRIES:-}"
    for c in "${carr[@]}"; do
        c="${c//[[:space:]]/}"
        [[ -z "${c}" ]] && continue
        countries_lower="${countries_lower}${countries_lower:+ }${c,,}"
    done

    local bypass_ips=""
    if [[ -n "${GEOIP_BYPASS_IPS:-}" ]]; then
        bypass_ips="${GEOIP_BYPASS_IPS//,/ }"
    fi

    {
        echo "(geoblock) {"
        if [[ -n "${bypass_ips}" ]]; then
            echo "    @geoip_bypass remote_ip ${bypass_ips}"
            echo ""
        fi
        if [[ "${GEOIP_MODE:-block}" == "allow" ]]; then
            # Default-deny: allow only the listed countries
            echo "    @geo_allowed maxmind_geolocation {"
            echo "        db_path ${mmdb}"
            [[ -n "${countries_lower}" ]] && echo "        allow_countries ${countries_lower}"
            echo "    }"
            echo ""
            if [[ -n "${bypass_ips}" ]]; then
                echo "    handle @geoip_bypass { }"
            fi
            echo "    handle @geo_allowed { }"
            echo "    handle {"
            echo "        respond \"Access denied\" 403"
            echo "    }"
        else
            # Default-allow: deny only the listed countries (default mode)
            echo "    @geo_blocked maxmind_geolocation {"
            echo "        db_path ${mmdb}"
            [[ -n "${countries_lower}" ]] && echo "        deny_countries ${countries_lower}"
            echo "    }"
            echo ""
            if [[ -n "${bypass_ips}" ]]; then
                echo "    handle @geoip_bypass { }"
            fi
            echo "    handle @geo_blocked {"
            echo "        respond \"Access denied\" 403"
            echo "    }"
        fi
        echo "}"
    } > "${SNIPPET}"
    chown root:caddy "${SNIPPET}"
    chmod 640 "${SNIPPET}"
}

# Rewrite the CrowdSec scenario from current country list
render_scenario() {
    [[ -d /etc/crowdsec/scenarios ]] || return 0
    load_config
    [[ "${GEOIP_ENABLED:-no}" == "yes" ]] || { rm -f "${SCENARIO}"; systemctl reload crowdsec 2>/dev/null || true; return 0; }
    local list=""
    IFS=',' read -ra carr <<<"${GEOIP_COUNTRIES:-}"
    for c in "${carr[@]}"; do
        c="${c//[[:space:]]/}"
        [[ -z "${c}" ]] && continue
        list="${list}${list:+, }\"${c^^}\""
    done
    local op="in"
    [[ "${GEOIP_MODE:-block}" == "allow" ]] && op="not in"
    cat > "${SCENARIO}" <<EOF
type: trigger
name: serverdeploy/geoblock
description: "Ban IP whose country is on the serverdeploy list (${GEOIP_MODE} mode)"
filter: |
  evt.Enriched.IsoCode != "" && evt.Enriched.IsoCode ${op} [${list}]
groupby: evt.Meta.source_ip
blackhole: 1m
labels:
  service: geoblock
  remediation: true
  type: geoip
EOF
    chmod 644 "${SCENARIO}"
    systemctl reload crowdsec 2>/dev/null || true
}

apply_or_rollback() {
    cp "${CONFIG}" "${CONFIG}.bak.$$"
    cp "${SNIPPET}" "${SNIPPET}.bak.$$" 2>/dev/null || true

    render_snippet
    if "${CADDY}" validate --config "${CADDYFILE}" --adapter caddyfile >/dev/null 2>&1; then
        systemctl reload caddy 2>/dev/null || warn "Caddy reload failed."
        render_scenario
        rm -f "${CONFIG}.bak.$$" "${SNIPPET}.bak.$$"
        success "Applied."
    else
        warn "Caddy validation failed — rolling back."
        mv "${CONFIG}.bak.$$" "${CONFIG}"
        [[ -f "${SNIPPET}.bak.$$" ]] && mv "${SNIPPET}.bak.$$" "${SNIPPET}"
        die "Rolled back. Run: ${CADDY} validate --config ${CADDYFILE} --adapter caddyfile"
    fi
}

# CSV helpers (case-insensitive country, exact match for IPs)
csv_contains() {
    local csv="$1" needle="$2"
    IFS=',' read -ra arr <<<"${csv}"
    for e in "${arr[@]}"; do
        e="${e//[[:space:]]/}"
        [[ "${e,,}" == "${needle,,}" ]] && return 0
    done
    return 1
}
csv_add() {
    local csv="$1" item="$2"
    if [[ -z "${csv}" ]]; then echo "${item}"; else echo "${csv},${item}"; fi
}
csv_remove() {
    local csv="$1" item="$2"
    local out=""
    IFS=',' read -ra arr <<<"${csv}"
    for e in "${arr[@]}"; do
        e="${e//[[:space:]]/}"
        [[ -z "${e}" ]] && continue
        if [[ "${e,,}" != "${item,,}" ]]; then out="${out:+${out},}${e}"; fi
    done
    echo "${out}"
}
csv_remove_index() {
    local csv="$1" target="$2"
    local i=1 out=""
    IFS=',' read -ra arr <<<"${csv}"
    for e in "${arr[@]}"; do
        e="${e//[[:space:]]/}"
        [[ -z "${e}" ]] && continue
        if [[ ${i} -ne ${target} ]]; then out="${out:+${out},}${e}"; fi
        i=$((i + 1))
    done
    echo "${out}"
}
csv_count() {
    local csv="$1" n=0
    IFS=',' read -ra arr <<<"${csv}"
    for e in "${arr[@]}"; do
        [[ -z "${e//[[:space:]]/}" ]] && continue
        n=$((n + 1))
    done
    echo "${n}"
}
csv_print_numbered() {
    local csv="$1" i=1
    IFS=',' read -ra arr <<<"${csv}"
    for e in "${arr[@]}"; do
        e="${e//[[:space:]]/}"
        [[ -z "${e}" ]] && continue
        printf '  %d) %s\n' "${i}" "${e}"
        i=$((i + 1))
    done
}

# -----------------------------------------------------------------------------
# Subcommands
# -----------------------------------------------------------------------------
load_config

cmd_status() {
    echo
    echo "  GEOIP_ENABLED   : ${GEOIP_ENABLED:-no}"
    echo "  GEOIP_MODE      : ${GEOIP_MODE:-block}"
    echo "  GEOIP_SOURCE    : ${GEOIP_SOURCE:-(none)}"
    echo "  Country list    : ${GEOIP_COUNTRIES:-(empty)}"
    echo "  Bypass IPs      : ${GEOIP_BYPASS_IPS:-(empty)}"
    echo "  mmdb            : $([[ -f /var/lib/GeoIP/GeoLite2-Country.mmdb ]] && stat -c '%s bytes, modified %y' /var/lib/GeoIP/GeoLite2-Country.mmdb || echo MISSING)"
    echo
    if [[ -d "${SITES_META}" ]]; then
        local n=0
        for meta in "${SITES_META}"/*.meta; do
            [[ -f "${meta}" ]] || continue
            if grep -q '^GEOIP_OVERRIDE="off"' "${meta}"; then
                [[ ${n} -eq 0 ]] && echo "  Sites with GeoIP DISABLED:"
                echo "    - $(basename "${meta}" .meta)"
                n=$((n + 1))
            fi
        done
        [[ ${n} -eq 0 ]] && echo "  All sites follow the global setting."
    fi
    echo
}

cmd_countries() {
    local sub="${1:-}"; shift || true
    case "${sub}" in
        list)
            if [[ -z "${GEOIP_COUNTRIES:-}" ]]; then
                info "Country list is empty."
            else
                echo
                csv_print_numbered "${GEOIP_COUNTRIES}"
                echo
            fi
            ;;
        set)
            local v="${1:-}"
            [[ -n "${v}" ]] || die "Usage: geoblock countries set RU,CN,KP"
            # Validate each ISO code
            IFS=',' read -ra arr <<<"${v}"
            for c in "${arr[@]}"; do
                c="${c//[[:space:]]/}"
                [[ "${c}" =~ ^[A-Za-z]{2}$ ]] || die "Invalid ISO code: ${c}"
            done
            # Normalize to uppercase
            local up=""
            for c in "${arr[@]}"; do
                c="${c//[[:space:]]/}"
                up="${up:+${up},}${c^^}"
            done
            audit "countries set: '${GEOIP_COUNTRIES}' → '${up}'"
            config_set GEOIP_COUNTRIES "${up}"
            apply_or_rollback
            ;;
        add)
            local c="${1:-}"
            [[ "${c}" =~ ^[A-Za-z]{2}$ ]] || die "Need a 2-letter ISO code."
            c="${c^^}"
            csv_contains "${GEOIP_COUNTRIES:-}" "${c}" && die "${c} already in list."
            local new
            new=$(csv_add "${GEOIP_COUNTRIES:-}" "${c}")
            audit "countries add: ${c}"
            config_set GEOIP_COUNTRIES "${new}"
            apply_or_rollback
            ;;
        remove)
            local c="${1:-}"
            [[ -n "${c}" ]] || die "Usage: geoblock countries remove RU"
            csv_contains "${GEOIP_COUNTRIES:-}" "${c}" || die "${c} not in list."
            local new
            new=$(csv_remove "${GEOIP_COUNTRIES:-}" "${c}")
            audit "countries remove: ${c}"
            config_set GEOIP_COUNTRIES "${new}"
            apply_or_rollback
            ;;
        *)
            die "Usage: geoblock countries set|add|remove|list ..."
            ;;
    esac
}

cmd_bypass() {
    local sub="${1:-}"; shift || true
    case "${sub}" in
        list)
            if [[ -z "${GEOIP_BYPASS_IPS:-}" ]]; then
                info "Bypass list is empty."
            else
                echo
                csv_print_numbered "${GEOIP_BYPASS_IPS}"
                echo
            fi
            ;;
        add)
            local ip="${1:-}"
            [[ -n "${ip}" ]] || die "Usage: geoblock bypass add <ip|cidr>"
            valid_ip_or_cidr "${ip}" || die "Not a valid IP/CIDR: ${ip}"
            csv_contains "${GEOIP_BYPASS_IPS:-}" "${ip}" && die "Already in bypass list."
            local new
            new=$(csv_add "${GEOIP_BYPASS_IPS:-}" "${ip}")
            audit "bypass add: ${ip}"
            config_set GEOIP_BYPASS_IPS "${new}"
            apply_or_rollback
            ;;
        remove)
            local cur="${GEOIP_BYPASS_IPS:-}"
            [[ -n "${cur}" ]] || die "Bypass list is empty."
            local arg="${1:-}"
            if [[ -n "${arg}" ]] && csv_contains "${cur}" "${arg}"; then
                local new
                new=$(csv_remove "${cur}" "${arg}")
                audit "bypass remove: ${arg}"
                config_set GEOIP_BYPASS_IPS "${new}"
                apply_or_rollback
                exit 0
            fi
            [[ -n "${arg}" ]] && warn "No exact match for '${arg}'. Current bypass list:"
            [[ -z "${arg}" ]] && info "Current bypass list:"
            csv_print_numbered "${cur}"
            echo
            prompt PICK "Number to remove (blank to abort)"
            [[ -z "${PICK}" ]] && { info "Aborted."; exit 0; }
            [[ "${PICK}" =~ ^[0-9]+$ ]] || die "Not a number."
            local cnt; cnt=$(csv_count "${cur}")
            (( PICK >= 1 && PICK <= cnt )) || die "Out of range."
            local new
            new=$(csv_remove_index "${cur}" "${PICK}")
            audit "bypass remove index ${PICK}"
            config_set GEOIP_BYPASS_IPS "${new}"
            apply_or_rollback
            ;;
        *)
            die "Usage: geoblock bypass add|remove|list ..."
            ;;
    esac
}

cmd_per_site() {
    local action="$1" domain="${2:-}"
    [[ -n "${domain}" ]] || die "Usage: geoblock ${action} <domain>"
    local meta="${SITES_META}/${domain}.meta"
    [[ -f "${meta}" ]] || die "No site found: ${domain}"
    local site_caddy
    # shellcheck disable=SC1090
    source "${meta}"
    site_caddy="${CADDY_FILE}"
    [[ -f "${site_caddy}" ]] || die "Site Caddy file missing: ${site_caddy}"

    case "${action}" in
        disable)
            grep -q '^GEOIP_OVERRIDE=' "${meta}" \
                && sed -i 's|^GEOIP_OVERRIDE=.*|GEOIP_OVERRIDE="off"|' "${meta}" \
                || echo 'GEOIP_OVERRIDE="off"' >> "${meta}"
            sed -i '/^[[:space:]]*import geoblock[[:space:]]*$/d' "${site_caddy}"
            audit "per-site disable: ${domain}"
            ;;
        enable)
            grep -q '^GEOIP_OVERRIDE=' "${meta}" \
                && sed -i 's|^GEOIP_OVERRIDE=.*|GEOIP_OVERRIDE="on"|' "${meta}" \
                || echo 'GEOIP_OVERRIDE="on"' >> "${meta}"
            if ! grep -q '^[[:space:]]*import geoblock[[:space:]]*$' "${site_caddy}"; then
                # Insert after `import waf` line
                sed -i '/^[[:space:]]*import waf[[:space:]]*$/a\    import geoblock' "${site_caddy}"
            fi
            audit "per-site enable: ${domain}"
            ;;
    esac

    if "${CADDY}" validate --config "${CADDYFILE}" --adapter caddyfile >/dev/null 2>&1; then
        systemctl reload caddy 2>/dev/null && success "Reloaded."
    else
        die "Caddy validation failed — manual fix needed: ${site_caddy}"
    fi
}

cmd_mode() {
    local m="${1:-}"
    case "${m}" in
        block|allow)
            audit "mode change: ${GEOIP_MODE:-block} → ${m}"
            config_set GEOIP_MODE "${m}"
            apply_or_rollback
            ;;
        *)
            die "Usage: geoblock mode block|allow"
            ;;
    esac
}

# -----------------------------------------------------------------------------
ACTION="${1:-}"
shift || true
case "${ACTION}" in
    status)    cmd_status ;;
    countries) cmd_countries "$@" ;;
    bypass)    cmd_bypass "$@" ;;
    disable)   cmd_per_site disable "$@" ;;
    enable)    cmd_per_site enable  "$@" ;;
    mode)      cmd_mode "$@" ;;
    *)
        cat <<USAGE
Usage:
  geoblock status
  geoblock countries set RU,CN,KP
  geoblock countries add IR
  geoblock countries remove RU
  geoblock countries list

  geoblock bypass add <ip|cidr>
  geoblock bypass remove [<ip|cidr>]
  geoblock bypass list

  geoblock disable <domain>
  geoblock enable  <domain>

  geoblock mode block|allow
USAGE
        exit 1
        ;;
esac
