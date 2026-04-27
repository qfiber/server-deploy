#!/bin/bash
# =============================================================================
# 30-runtimes.sh — Node.js 22 LTS + PHP-FPM 8.3
#   - Node from NodeSource RPM (security updates via dnf)
#   - PHP from Remi (AlmaLinux only ships 8.2/8.3 via streams; Remi gives us 8.3)
#   - default php-fpm pool disabled (per-tenant pools added later by newsite-php.sh)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${REPO_DIR}/lib/common.sh"

require_root

NODE_MAJOR=22
PHP_VERSION=8.3

# -----------------------------------------------------------------------------
# 1. Node.js 22 LTS
# -----------------------------------------------------------------------------
if command -v node >/dev/null 2>&1 && node --version 2>/dev/null | grep -q "^v${NODE_MAJOR}\."; then
    info "Node.js ${NODE_MAJOR} already installed: $(node --version)"
else
    info "Installing Node.js ${NODE_MAJOR} LTS via NodeSource..."
    curl -fsSL "https://rpm.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
    dnf -y install nodejs
fi
success "Node.js $(node --version), npm $(npm --version)."

# WP-CLI (WordPress command-line management)
if command -v wp >/dev/null 2>&1; then
    info "WP-CLI already installed."
else
    info "Installing WP-CLI..."
    curl -fsSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -o /usr/local/bin/wp
    chmod 755 /usr/local/bin/wp
fi
success "WP-CLI $(wp --allow-root --version 2>/dev/null)."

# -----------------------------------------------------------------------------
# 2. PHP 8.3 + extensions (via Remi)
# -----------------------------------------------------------------------------
if php --version 2>/dev/null | head -1 | grep -q "^PHP ${PHP_VERSION}"; then
    info "PHP ${PHP_VERSION} already installed."
else
    info "Installing PHP ${PHP_VERSION} via Remi..."
    if ! rpm -q remi-release >/dev/null 2>&1; then
        dnf -y install "https://rpms.remirepo.net/enterprise/remi-release-9.rpm"
    fi
    dnf -y install dnf-plugins-core
    dnf module reset -y php
    dnf module enable -y "php:remi-${PHP_VERSION}"

    dnf -y install \
        php-fpm php-cli php-common \
        php-mysqlnd php-pgsql \
        php-gd php-pecl-imagick-im7 \
        php-curl php-mbstring php-xml php-zip \
        php-intl php-opcache php-bcmath \
        php-soap php-pecl-redis6 \
        php-process php-sodium php-fileinfo
fi
success "PHP $(php --version | head -1 | awk '{print $2}') installed."

# -----------------------------------------------------------------------------
# 3. PHP / PHP-FPM tuning
# -----------------------------------------------------------------------------
info "Tuning php.ini..."
PHP_INI=/etc/php.ini
if [[ -f "${PHP_INI}" ]]; then
    sed -i \
        -e 's/^memory_limit = .*/memory_limit = 256M/' \
        -e 's/^upload_max_filesize = .*/upload_max_filesize = 64M/' \
        -e 's/^post_max_size = .*/post_max_size = 64M/' \
        -e 's/^max_execution_time = .*/max_execution_time = 60/' \
        -e 's|^;date.timezone =.*|date.timezone = Asia/Jerusalem|' \
        -e 's/^expose_php = On/expose_php = Off/' \
        "${PHP_INI}"
fi

# Disable default www pool — per-tenant pools come from newsite-php.sh
if [[ -f /etc/php-fpm.d/www.conf ]]; then
    info "Disabling default php-fpm www pool..."
    mv /etc/php-fpm.d/www.conf /etc/php-fpm.d/www.conf.disabled
fi

mkdir -p /etc/php-fpm.d /run/php-fpm
chown root:root /etc/php-fpm.d

# Idle pool — keeps php-fpm alive even when no tenant pools exist.
# Uses near-zero resources (ondemand, 1 worker, 10s idle timeout).
cat > /etc/php-fpm.d/00-idle.conf <<'IDLE'
; Minimal idle pool — keeps php-fpm running when no tenant pools exist.
; Managed by serverdeploy — do not remove.
[idle]
user = nobody
group = nobody
listen = /run/php-fpm/idle.sock
listen.mode = 0600
pm = ondemand
pm.max_children = 1
pm.process_idle_timeout = 10s
IDLE

systemctl enable --now php-fpm

# -----------------------------------------------------------------------------
# Done
# -----------------------------------------------------------------------------
echo
success "30-runtimes.sh complete."
info "  Node.js : $(node --version)"
info "  npm     : $(npm --version)"
info "  PHP     : $(php --version | head -1 | awk '{print $2}')"
info "  php-fpm : running (idle pool keeps master alive)"
