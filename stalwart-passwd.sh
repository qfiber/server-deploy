#!/bin/bash
# Change Stalwart admin password via config.toml
# Usage: stalwart-passwd [new-password]
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }

CONFIG=/opt/stalwart/etc/config.toml
CRED_FILE=/etc/serverdeploy/stalwart-admin.txt

if [[ -n "${1:-}" ]]; then
    NEW_PASS="$1"
else
    read -rsp "New admin password: " NEW_PASS
    echo
    read -rsp "Confirm: " CONFIRM
    echo
    [[ "${NEW_PASS}" == "${CONFIRM}" ]] || { echo "Passwords do not match."; exit 1; }
fi

[[ ${#NEW_PASS} -ge 8 ]] || { echo "Password must be at least 8 characters."; exit 1; }

NEW_HASH=$(openssl passwd -6 "${NEW_PASS}")
sed -i "s|^authentication.fallback-admin.secret = .*|authentication.fallback-admin.secret = \"${NEW_HASH}\"|" "${CONFIG}"
echo "admin: ${NEW_PASS}" > "${CRED_FILE}"
chmod 600 "${CRED_FILE}"
systemctl restart stalwart
echo "Password changed. Saved to ${CRED_FILE}."
