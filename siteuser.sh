#!/bin/bash
# =============================================================================
# siteuser.sh — manage SSH/SFTP access scoped to a single site
# Run as: root
#
# Usage:
#   siteuser add  <domain> <username> [--key <pubkey-or-file>] [--shell]
#   siteuser del  <domain> <username>
#   siteuser list <domain>
#
# Behavior:
#   - Creates a normal Linux user, adds them to the site's group.
#   - Default = SFTP-only with chroot to the site dir (safest).
#   - --shell = real login shell, no chroot (so they can run npm/composer/etc.)
#   - Per-user sshd drop-in at /etc/ssh/sshd_config.d/50-siteuser-<user>.conf.
#   - Sudoers drop-in lets them restart their site's systemd units only.
#   - Tracked in /etc/serverdeploy/sites/<domain>.users for delsite to clean up.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for candidate in "/usr/local/lib/serverdeploy" "${SCRIPT_DIR}/lib"; do
    [[ -f "${candidate}/common.sh" ]] && { source "${candidate}/common.sh"; break; }
done
type require_root >/dev/null 2>&1 || { echo "[ERROR] common.sh not found"; exit 1; }

require_root

STATE_DIR="/etc/serverdeploy/sites"
SSHD_DROPIN_DIR="/etc/ssh/sshd_config.d"
SUDOERS_DIR="/etc/sudoers.d"

usage() {
    sed -n '4,16p' "$0"
    exit 1
}

ACTION="${1:-}"
DOMAIN="${2:-}"
USER_TO="${3:-}"
shift 3 2>/dev/null || true

KEY_INPUT=""
SHELL_MODE="sftp"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --key)   KEY_INPUT="$2"; shift 2 ;;
        --shell) SHELL_MODE="shell"; shift ;;
        *)       die "Unknown flag: $1" ;;
    esac
done

[[ -n "${ACTION}" && -n "${DOMAIN}" ]] || usage
[[ "${ACTION}" == "list" || -n "${USER_TO}" ]] || usage

META="${STATE_DIR}/${DOMAIN}.meta"
[[ -f "${META}" ]] || die "No site found at ${META}"
# shellcheck disable=SC1090
source "${META}"
SITE_GROUP="${USERNAME}"
USERS_FILE="${STATE_DIR}/${DOMAIN}.users"
touch "${USERS_FILE}"
chmod 600 "${USERS_FILE}"

cmd_list() {
    if [[ ! -s "${USERS_FILE}" ]]; then
        info "No site users for ${DOMAIN}."
        return 0
    fi
    echo
    printf '%-20s %-8s %s\n' "USER" "MODE" "ADDED"
    printf '%-20s %-8s %s\n' "----" "----" "-----"
    while IFS=':' read -r u mode added; do
        printf '%-20s %-8s %s\n' "${u}" "${mode}" "${added}"
    done < "${USERS_FILE}"
    echo
}

cmd_del() {
    grep -qE "^${USER_TO}:" "${USERS_FILE}" || die "${USER_TO} is not a site user of ${DOMAIN}."

    info "Removing ${USER_TO}..."
    rm -f "${SSHD_DROPIN_DIR}/50-siteuser-${USER_TO}.conf"
    rm -f "${SUDOERS_DIR}/serverdeploy-${USER_TO}"

    if id "${USER_TO}" >/dev/null 2>&1; then
        pkill -u "${USER_TO}" 2>/dev/null || true
        sleep 0.3
        userdel -r "${USER_TO}" 2>/dev/null || userdel "${USER_TO}" 2>/dev/null || warn "userdel failed."
    fi

    sed -i "/^${USER_TO}:/d" "${USERS_FILE}"
    sshd -t || die "sshd config invalid after removal."
    systemctl reload sshd
    success "${USER_TO} removed from ${DOMAIN}."
}

cmd_add() {
    grep -qE "^${USER_TO}:" "${USERS_FILE}" && die "${USER_TO} already a site user of ${DOMAIN}."
    id "${USER_TO}" >/dev/null 2>&1 && die "System user ${USER_TO} already exists."

    # Resolve the public key
    local pubkey=""
    if [[ -n "${KEY_INPUT}" ]]; then
        if [[ -f "${KEY_INPUT}" ]]; then
            pubkey=$(<"${KEY_INPUT}")
        else
            pubkey="${KEY_INPUT}"
        fi
    else
        prompt_required pubkey "SSH public key (paste full single line)"
    fi
    [[ "${pubkey}" =~ ^(ssh-(ed25519|rsa|ecdsa)|ecdsa-sha2)|sk-ssh- ]] || die "That doesn't look like an SSH public key."

    info "Creating ${USER_TO} (${SHELL_MODE} mode)..."

    if [[ "${SHELL_MODE}" == "sftp" ]]; then
        # SFTP chroot requires home outside chroot to be root-owned
        useradd --system --shell /sbin/nologin --no-create-home \
                --gid "${SITE_GROUP}" \
                --home-dir "${SITE_DIR}" \
                "${USER_TO}"
        # SSH dir lives under /var/lib/site-users so it's outside the chroot
        mkdir -p "/var/lib/site-users/${USER_TO}/.ssh"
        chmod 700 "/var/lib/site-users/${USER_TO}/.ssh"
        echo "${pubkey}" > "/var/lib/site-users/${USER_TO}/.ssh/authorized_keys"
        chmod 600 "/var/lib/site-users/${USER_TO}/.ssh/authorized_keys"
        chown -R "${USER_TO}:${SITE_GROUP}" "/var/lib/site-users/${USER_TO}"

        # Site dir owned <site>:<group>; group already gets 2770 from newsite.sh
        # so this user can read/write into the chroot.
        cat > "${SSHD_DROPIN_DIR}/50-siteuser-${USER_TO}.conf" <<EOF
# serverdeploy site-user ${USER_TO} → ${DOMAIN} (sftp-only)
Match User ${USER_TO}
    AuthorizedKeysFile /var/lib/site-users/%u/.ssh/authorized_keys
    ChrootDirectory ${SITE_DIR}
    ForceCommand internal-sftp -d /
    AllowTcpForwarding no
    X11Forwarding no
    PermitTunnel no
    PermitTTY no
EOF
    else  # shell mode
        mkdir -p "/home/${USER_TO}"
        useradd --shell /bin/bash \
                --gid "${SITE_GROUP}" \
                --home-dir "/home/${USER_TO}" \
                --create-home \
                "${USER_TO}"
        mkdir -p "/home/${USER_TO}/.ssh"
        echo "${pubkey}" > "/home/${USER_TO}/.ssh/authorized_keys"
        chmod 700 "/home/${USER_TO}/.ssh"
        chmod 600 "/home/${USER_TO}/.ssh/authorized_keys"
        chown -R "${USER_TO}:${SITE_GROUP}" "/home/${USER_TO}"

        cat > "${SSHD_DROPIN_DIR}/50-siteuser-${USER_TO}.conf" <<EOF
# serverdeploy site-user ${USER_TO} → ${DOMAIN} (shell)
Match User ${USER_TO}
    AllowTcpForwarding no
    X11Forwarding no
    PermitTunnel no
    AllowAgentForwarding no
EOF

        # Sudoers — restart their own units only
        if [[ "${SITE_TYPE}" == "node" && -n "${SYSTEMD_UNITS:-}" ]]; then
            local cmds=""
            IFS=',' read -ra units <<< "${SYSTEMD_UNITS}"
            for u in "${units[@]}"; do
                [[ -z "${u}" ]] && continue
                cmds="${cmds}/bin/systemctl restart ${u}.service, /bin/systemctl status ${u}.service, /bin/journalctl -u ${u}.service*, "
            done
            cmds="${cmds%, }"
            if [[ -n "${cmds}" ]]; then
                cat > "${SUDOERS_DIR}/serverdeploy-${USER_TO}" <<EOF
${USER_TO} ALL=(root) NOPASSWD: ${cmds}
EOF
                chmod 440 "${SUDOERS_DIR}/serverdeploy-${USER_TO}"
                visudo -c -f "${SUDOERS_DIR}/serverdeploy-${USER_TO}" >/dev/null || \
                    { rm -f "${SUDOERS_DIR}/serverdeploy-${USER_TO}"; die "Sudoers drop-in invalid."; }
            fi
        fi
    fi

    sshd -t || die "sshd config invalid — rolling back."
    systemctl reload sshd

    echo "${USER_TO}:${SHELL_MODE}:$(date -Iseconds)" >> "${USERS_FILE}"

    echo
    success "${USER_TO} added to ${DOMAIN} (${SHELL_MODE})."
    if [[ "${SHELL_MODE}" == "sftp" ]]; then
        info "Connect with: sftp -P <ssh-port> ${USER_TO}@<server>"
        info "Files appear at the chroot root ('/'); they map to ${SITE_DIR} on disk."
    else
        info "Connect with: ssh -p <ssh-port> ${USER_TO}@<server>"
        info "User has write access to ${SITE_DIR} via group ${SITE_GROUP}."
        [[ -n "${SYSTEMD_UNITS:-}" ]] && info "User can: sudo systemctl restart/status ${SYSTEMD_UNITS}"
    fi
}

case "${ACTION}" in
    add)  cmd_add ;;
    del)  cmd_del ;;
    list) cmd_list ;;
    *)    usage ;;
esac
