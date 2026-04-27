#!/bin/bash
# =============================================================================
# 40-crowdsec.sh — CrowdSec + nftables firewall bouncer
#   - install crowdsec from upstream repo
#   - install collections: linux, sshd, base-http-scenarios
#   - acquire Caddy logs (best-effort — no native Caddy parser yet)
#   - install + register crowdsec-firewall-bouncer-nftables
#   - drops attackers at the firewall layer (matches firewalld nftables backend)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${REPO_DIR}/lib/common.sh"

require_root

# -----------------------------------------------------------------------------
# 1. Install CrowdSec + bouncer
# -----------------------------------------------------------------------------
if rpm -q crowdsec >/dev/null 2>&1; then
    info "CrowdSec already installed."
else
    info "Adding CrowdSec repository..."
    curl -fsSL https://install.crowdsec.net | bash
    info "Installing crowdsec + nftables bouncer..."
    dnf -y install crowdsec crowdsec-firewall-bouncer-nftables
fi

# -----------------------------------------------------------------------------
# 2. Hub update + collections
# -----------------------------------------------------------------------------
info "Updating CrowdSec hub..."
cscli hub update >/dev/null

info "Installing collections + parsers..."
for item in \
    "collections crowdsecurity/linux" \
    "collections crowdsecurity/sshd" \
    "collections crowdsecurity/base-http-scenarios" \
    "collections crowdsecurity/http-cve" \
    "collections crowdsecurity/caddy" \
    "scenarios   crowdsecurity/http-bf-wordpress_bf" \
    "scenarios   crowdsecurity/http-crawl-non_statics" \
    "scenarios   crowdsecurity/http-probing" \
    "scenarios   crowdsecurity/http-sensitive-files"; do
    kind="${item%% *}"
    name="${item##* }"
    if cscli "${kind}" list -o raw 2>/dev/null | grep -q "^${name},"; then
        info "  ${kind}/${name}: already installed"
    else
        cscli "${kind}" install "${name}" >/dev/null 2>&1 && \
            success "  ${kind}/${name} installed" || \
            warn "  ${kind}/${name} install failed (continuing)"
    fi
done

# -----------------------------------------------------------------------------
# 3. Acquisitions — Caddy + sshd
# -----------------------------------------------------------------------------
info "Writing acquisitions..."
mkdir -p /etc/crowdsec/acquis.d
cat > /etc/crowdsec/acquis.d/caddy.yaml <<'EOF'
filenames:
  - /var/log/caddy/*.log
labels:
  type: caddy
EOF
cat > /etc/crowdsec/acquis.d/sshd.yaml <<'EOF'
source: journalctl
journalctl_filter:
  - "_SYSTEMD_UNIT=sshd.service"
labels:
  type: syslog
EOF
success "Acquisition files written."

# -----------------------------------------------------------------------------
# 4. Start crowdsec
# -----------------------------------------------------------------------------
systemctl enable crowdsec
systemctl restart crowdsec
sleep 2
systemctl is-active --quiet crowdsec || die "crowdsec failed to start. journalctl -u crowdsec"
success "crowdsec running."

# -----------------------------------------------------------------------------
# 5. Register firewall bouncer
# -----------------------------------------------------------------------------
BOUNCER_CONF=/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml

needs_register=1
if [[ -f "${BOUNCER_CONF}" ]] && grep -qE '^api_key:[[:space:]]+[A-Za-z0-9]' "${BOUNCER_CONF}"; then
    needs_register=0
    info "Firewall bouncer api_key already set in ${BOUNCER_CONF}"
fi

if [[ ${needs_register} -eq 1 ]]; then
    info "Registering firewall bouncer with local CrowdSec API..."
    # Drop any pre-existing entry from a half-finished previous run
    cscli bouncers delete firewall-bouncer 2>/dev/null || true
    KEY=$(cscli bouncers add firewall-bouncer -o raw 2>/dev/null || true)
    [[ -n "${KEY}" ]] || die "Failed to register firewall bouncer."
    sed -i "s|^api_key:.*|api_key: ${KEY}|" "${BOUNCER_CONF}"
    success "Firewall bouncer api_key set."
fi

systemctl enable crowdsec-firewall-bouncer
systemctl restart crowdsec-firewall-bouncer
sleep 1
systemctl is-active --quiet crowdsec-firewall-bouncer || \
    die "crowdsec-firewall-bouncer failed to start. journalctl -u crowdsec-firewall-bouncer"
success "Firewall bouncer running."

# -----------------------------------------------------------------------------
# Done
# -----------------------------------------------------------------------------
echo
success "40-crowdsec.sh complete."
info "  cscli metrics            view detection metrics"
info "  cscli decisions list     see active blocks"
info "  cscli bouncers list      list registered bouncers"
info "  cscli alerts list        recent alerts"
info ""
info "  CrowdSec console (free):  https://app.crowdsec.net  — optional"
