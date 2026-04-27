#!/bin/bash
# =============================================================================
# 45-geoip.sh — GeoIP country block
#
# Two layers:
#   1. CrowdSec geoip-aware scenario — bans at the firewall.
#   2. Caddy maxmind_geolocation matcher — per-site allow/deny + per-IP bypass.
#
# Sources (set at install in /etc/serverdeploy/config):
#   GEOIP_SOURCE=offline → copies <MAXMIND_OFFLINE_DIR>/GeoLite2-Country.mmdb
#                          into /var/lib/GeoIP/.
#   GEOIP_SOURCE=api     → installs geoipupdate, runs once, weekly cron.
#
# Mode: GEOIP_MODE=block (default-allow, deny GEOIP_COUNTRIES)
#       (allow-mode = default-deny is also supported by geoblock.sh later)
#
# Idempotent — re-run after toggling GEOIP_ENABLED to flip the feature on/off.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${REPO_DIR}/lib/common.sh"

require_root
load_config

if [[ "${GEOIP_ENABLED:-no}" != "yes" ]]; then
    info "GEOIP_ENABLED=no — skipping (and removing any existing geoip wiring)."
    rm -f /etc/cron.d/serverdeploy-geoipupdate
    rm -f /etc/crowdsec/parsers/s02-enrich/geoip-enrich.yaml.disabled 2>/dev/null || true
    rm -f /etc/crowdsec/scenarios/serverdeploy-geoblock.yaml
    systemctl reload crowdsec 2>/dev/null || true
    exit 0
fi

GEOIP_DIR=/var/lib/GeoIP
MMDB="${GEOIP_DIR}/GeoLite2-Country.mmdb"
mkdir -p "${GEOIP_DIR}"
chmod 755 "${GEOIP_DIR}"

# -----------------------------------------------------------------------------
# 1. Source the mmdb file
# -----------------------------------------------------------------------------
case "${GEOIP_SOURCE:-}" in
    offline)
        SRC="${MAXMIND_OFFLINE_DIR%/}/GeoLite2-Country.mmdb"
        [[ -f "${SRC}" ]] || die "Offline mmdb not found at ${SRC}"
        info "Seeding ${MMDB} from ${SRC}..."
        install -m 0644 -o root -g root "${SRC}" "${MMDB}"
        # Optional: City db if user dropped it
        if [[ -f "${MAXMIND_OFFLINE_DIR%/}/GeoLite2-City.mmdb" ]]; then
            install -m 0644 -o root -g root "${MAXMIND_OFFLINE_DIR%/}/GeoLite2-City.mmdb" \
                "${GEOIP_DIR}/GeoLite2-City.mmdb"
        fi
        # ASN db (optional but useful for CrowdSec)
        if [[ -f "${MAXMIND_OFFLINE_DIR%/}/GeoLite2-ASN.mmdb" ]]; then
            install -m 0644 -o root -g root "${MAXMIND_OFFLINE_DIR%/}/GeoLite2-ASN.mmdb" \
                "${GEOIP_DIR}/GeoLite2-ASN.mmdb"
        fi
        rm -f /etc/cron.d/serverdeploy-geoipupdate
        success "mmdb seeded from offline files."
        warn "Refresh manually by re-dropping files into ${MAXMIND_OFFLINE_DIR}"
        warn "and re-running this stage, or run: ./bootstrap.sh 45-geoip.sh"
        ;;
    api)
        info "Installing geoipupdate..."
        rpm -q geoipupdate >/dev/null 2>&1 || dnf -y install geoipupdate
        cat > /etc/GeoIP.conf <<EOF
AccountID ${MAXMIND_ACCOUNT_ID}
LicenseKey ${MAXMIND_LICENSE_KEY}
EditionIDs GeoLite2-Country GeoLite2-City GeoLite2-ASN
DatabaseDirectory ${GEOIP_DIR}
EOF
        chmod 600 /etc/GeoIP.conf
        info "Running geoipupdate..."
        geoipupdate -v || die "geoipupdate failed."
        cat > /etc/cron.d/serverdeploy-geoipupdate <<'CRON'
# Weekly MaxMind refresh (Wed 04:15) + reload caddy/crowdsec on change
15 4 * * 3 root /usr/bin/geoipupdate >> /var/log/serverdeploy/geoipupdate.log 2>&1 && systemctl reload crowdsec >/dev/null 2>&1 ; systemctl reload caddy >/dev/null 2>&1 || true
CRON
        chmod 644 /etc/cron.d/serverdeploy-geoipupdate
        success "geoipupdate installed; weekly refresh scheduled."
        ;;
    *)
        die "GEOIP_SOURCE must be 'offline' or 'api'."
        ;;
esac

[[ -f "${MMDB}" ]] || die "${MMDB} missing after seeding."

# -----------------------------------------------------------------------------
# 2. CrowdSec geoip-enrich + ban scenario
# -----------------------------------------------------------------------------
if command -v cscli >/dev/null 2>&1; then
    info "Wiring CrowdSec geoip enrichment..."
    cscli parsers install crowdsecurity/geoip-enrich >/dev/null 2>&1 || \
        info "  geoip-enrich already installed."

    # Custom scenario: ban any IP whose country code is in GEOIP_COUNTRIES.
    # We materialize the country list into the scenario at install time and
    # rewrite it whenever geoblock.sh edits the list.
    CSV="${GEOIP_COUNTRIES}"
    # Convert "RU,CN,KP" → '"RU","CN","KP"' for the scenario YAML
    LIST=""
    IFS=',' read -ra arr <<<"${CSV}"
    for c in "${arr[@]}"; do
        c="${c//[[:space:]]/}"
        [[ -z "${c}" ]] && continue
        LIST="${LIST}${LIST:+, }\"${c^^}\""
    done

    cat > /etc/crowdsec/scenarios/serverdeploy-geoblock.yaml <<EOF
type: trigger
name: serverdeploy/geoblock
description: "Ban any IP from a serverdeploy-blocked country"
filter: |
  evt.Enriched.IsoCode != "" && evt.Enriched.IsoCode in [${LIST}]
groupby: evt.Meta.source_ip
blackhole: 1m
labels:
  service: geoblock
  remediation: true
  type: geoip
EOF
    chmod 644 /etc/crowdsec/scenarios/serverdeploy-geoblock.yaml

    # CDN whitelist — when traffic comes through a CDN, CrowdSec sees the CDN's
    # IP. We register a whitelist that drops alerts whose source_ip is a CDN
    # edge IP, so we don't ban the CDN. The Layer 7 (Caddy) check still
    # applies the country block based on the real client IP after
    # trusted_proxies unwrap the CDN header.
    cat > /etc/crowdsec/postoverflows/s00-enrich/serverdeploy-cdn-whitelist.yaml <<'EOF'
name: serverdeploy/cdn-whitelist
description: "Don't ban CDN edge IPs — Caddy will country-block on the unwrapped client IP"
whitelist:
  reason: "CDN edge"
  cidr:
    # Cloudflare
    - "173.245.48.0/20"
    - "103.21.244.0/22"
    - "103.22.200.0/22"
    - "103.31.4.0/22"
    - "141.101.64.0/18"
    - "108.162.192.0/18"
    - "190.93.240.0/20"
    - "188.114.96.0/20"
    - "197.234.240.0/22"
    - "198.41.128.0/17"
    - "162.158.0.0/15"
    - "104.16.0.0/13"
    - "104.24.0.0/14"
    - "172.64.0.0/13"
    - "131.0.72.0/22"
    # Fastly (anycast)
    - "23.235.32.0/20"
    - "43.249.72.0/22"
    - "103.244.50.0/24"
    - "103.245.222.0/23"
    - "103.245.224.0/24"
    - "104.156.80.0/20"
    - "140.248.64.0/18"
    - "140.248.128.0/17"
    - "146.75.0.0/17"
    - "151.101.0.0/16"
    - "157.52.64.0/18"
    - "167.82.0.0/17"
    - "167.82.128.0/20"
    - "167.82.160.0/20"
    - "167.82.224.0/20"
    - "172.111.64.0/18"
    - "185.31.16.0/22"
    - "199.27.72.0/21"
    - "199.232.0.0/16"
    # Akamai
    - "23.32.0.0/11"
    - "23.64.0.0/14"
    - "23.72.0.0/13"
    - "104.64.0.0/10"
    - "184.24.0.0/13"
    - "184.50.0.0/15"
    - "184.84.0.0/14"
    # AWS CloudFront (top-level — fine-grained list refreshed by aws-ip-ranges)
    - "13.32.0.0/15"
    - "13.224.0.0/14"
    - "52.84.0.0/15"
    - "52.124.128.0/17"
    - "54.182.0.0/16"
    - "54.192.0.0/16"
    - "54.230.0.0/16"
    - "54.239.128.0/18"
    - "54.239.192.0/19"
    - "54.240.128.0/18"
    - "204.246.164.0/22"
    - "204.246.168.0/22"
    - "204.246.174.0/23"
    - "204.246.176.0/20"
    - "205.251.192.0/19"
    - "216.137.32.0/19"
    # Bunny.net
    - "23.83.128.0/19"
    - "85.119.83.0/24"
    - "138.199.0.0/16"
    - "143.244.40.0/22"
    - "172.66.0.0/16"
    # Sucuri
    - "192.124.249.0/24"
    - "185.93.228.0/22"
    - "66.248.200.0/22"
    - "208.109.0.0/22"
    # Stackpath / Highwinds
    - "151.139.0.0/19"
EOF
    mkdir -p /etc/crowdsec/postoverflows/s00-enrich
    chmod 644 /etc/crowdsec/postoverflows/s00-enrich/serverdeploy-cdn-whitelist.yaml

    systemctl reload crowdsec 2>/dev/null || systemctl restart crowdsec || true
    success "CrowdSec geoip scenario + CDN whitelist applied."
else
    warn "cscli not found — skipping CrowdSec wiring (run 40-crowdsec.sh first)."
fi

# -----------------------------------------------------------------------------
# 3. Reload Caddy to pick up the new mmdb (no-op if not yet built with the
#    maxmind_geolocation module — 10-caddy.sh handles the rebuild)
# -----------------------------------------------------------------------------
if systemctl is-active --quiet caddy 2>/dev/null; then
    systemctl reload caddy 2>/dev/null || true
fi

echo
success "45-geoip.sh complete."
info "  mmdb       : ${MMDB}"
info "  source     : ${GEOIP_SOURCE}"
info "  mode       : ${GEOIP_MODE}"
info "  countries  : ${GEOIP_COUNTRIES}"
info ""
info "  Manage with:  geoblock countries set/add/remove ..."
info "                geoblock bypass add/remove <ip>"
info "                geoblock disable/enable <domain>"
