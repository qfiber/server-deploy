# serverdeploy

A complete, opinionated hosting stack on a single AlmaLinux 9 server. One operator, multiple client sites, no Docker, no Kubernetes, no cloud control plane. Every piece is a regular `systemd` service you can `systemctl status`, and every secret lives in one config file you can `cat`.

If you are a junior sysadmin and have never set up a multi-tenant box before, this README will walk you through it from start to finish.

---

## What you get

After running the bootstrap, the server has:

- **Caddy** as the web server, with the **OWASP Coraza WAF** in front of every site, automatic Let's Encrypt certificates, HTTP/3, security headers, and rate limiting on admin pages
- **MariaDB 12** and **PostgreSQL 16** for databases (each tenant gets their own DB user with a random password)
- **PHP-FPM 8.3** for WordPress / Laravel / generic PHP, with each site sandboxed (`open_basedir`, dedicated user, dangerous functions disabled)
- **Node.js 22** for Express / Next.js / API+SPA apps, each as a hardened systemd unit
- **CrowdSec** + nftables firewall bouncer (real-time IP banning based on attack patterns)
- **GeoIP country block** (MaxMind) with multi-CDN trusted-proxy support and per-IP bypass
- **Stalwart Mail Server** for inbound mail to client domains, with per-domain DKIM
- **Restic encrypted backups** to Backblaze B2
- **phpMyAdmin** and/or **pgAdmin4** if you want a web UI for databases (each behind IP allowlist + HTTP basic auth + rate limit + WAF)
- **Per-minute health monitoring** with email alerts on disk/RAM/swap/CPU/cert/backup/site-down/etc., with a 15-minute cooldown so you don't get spammed
- **One-command tools** for adding sites, removing sites, restoring sites, managing site SSH users, tuning the WAF, managing the IP allowlist, and managing the country block

---

## What you'll need

Before you start, gather:

- A fresh AlmaLinux 9 server (4 GB RAM minimum; 8 GB if you'll run a database-heavy WordPress)
- Root access (initially via password — you'll switch to key-only during install)
- Your laptop's SSH **public** key (`cat ~/.ssh/id_ed25519.pub`)
- An admin email address (where alerts go)
- A domain you control, with the ability to edit DNS records
- The IP address you'll administer the server from (for the admin allowlist)
- (Optional) MaxMind GeoLite2 mmdb files OR a MaxMind license key — for country blocking
- (Optional) A Resend API key OR generic SMTP credentials — for outbound mail
- (Optional) Backblaze B2 bucket + application key — for backups

You don't need any of the optional items to install. You can skip them and add them later by re-running the relevant stage.

---

## Part 1 — First-time deployment

### Step 1: Set the server's fully-qualified hostname

DNS for this hostname must point to the server before you finish. The server uses this name as its mail HELO identity and as the source of its TLS certificate.

```bash
# Pick a hostname. Examples:
#   srv1.example.com    (you own example.com)
#   cp.acme.io          (you own acme.io — "cp" stands for "control panel")
hostnamectl set-hostname srv1.example.com
```

Verify it's set:

```bash
hostname -f
# Should print: srv1.example.com
```

### Step 2: Create DNS records (do this now, before bootstrapping)

DNS takes a few minutes to propagate. Set these up now so they're ready by the time the install needs them:

| Record | Name | Value | Why |
|---|---|---|---|
| A | `srv1` (or whatever) | your server's public IP | Server hostname / TLS / mail HELO |
| A | `mail` | your server's public IP | Mail admin panel (Stalwart) |
| A | `pma` | your server's public IP | phpMyAdmin (only if you'll install it) |
| A | `pga` | your server's public IP | pgAdmin4 (only if you'll install it) |

If your server is behind NAT (e.g., a home lab), use the **public** IP — bootstrap will detect this and warn you.

### Step 3: Get the code on the server

```bash
ssh root@<your-server-ip>
cd /root
git clone <this-repo-url> serverdeploy
cd serverdeploy
```

(Or `scp -r serverdeploy/ root@<server>:/root/` if you don't have git on the box yet.)

### Step 4: Run bootstrap

```bash
./bootstrap.sh
```

The script asks questions one by one. Here's what each prompt means and what to type:

#### Identity
- **Admin email** — where alerts go. e.g., `you@example.com`
- **Sender display name** — appears in alert emails. Default = your hostname.
- **Sender 'From' address** — usually same as admin email.

#### Server hostname
- **Server hostname (FQDN)** — pre-filled with what you set in step 1. Just press Enter.

#### Timezone
- **Timezone** — IANA name. `UTC` is fine if you don't care; `America/New_York`, `Europe/London`, `Asia/Tokyo`, etc. otherwise.

#### SSH
- **SSH public key** — paste the entire single line of your laptop's `~/.ssh/id_ed25519.pub` (or `id_rsa.pub`). After install, password login is disabled.
- **SSH port** — default `2223`. Change only if 2223 is already in use.

#### Mail admin panel
- **Mail admin panel hostname** — default `mail.<your-domain>`. This is where you'll log into Stalwart.
- **Admin allowlist** — comma-separated IPs/CIDRs of who can reach the admin panels. Put **your home/office IP**. Example: `203.0.113.7,2001:db8::/32`. Don't use `0.0.0.0/0` here — that opens admin pages to the world.

#### DKIM selector
- **DKIM selector** — leave as `default` unless you have a reason to change.

#### Database admin tooling
- `1) phpMyAdmin` — install only if you'll use MariaDB and want a web UI
- `2) pgAdmin4` — install only if you'll use Postgres and want a web UI
- `3) Both` — install both
- `4) None` — recommended for paranoid setups

If you pick 1, 2, or 3, it'll ask for the hostname (default `pma.<domain>` and `pga.<domain>`).

#### GeoIP block
- **Enable GeoIP block?** — `y` blocks visitors from listed countries. `n` skips it.
- If yes:
  - **Source 1) Offline files** — point at a directory containing `GeoLite2-Country.mmdb` (you provide the file)
  - **Source 2) API** — supply MaxMind account ID + license key (free signup at maxmind.com)
- **Country list** — defaults to `RU,CN,BY,AU,IN,NG,KP`. Change if you want.

#### Outbound mail relay (for alerts)
Three choices:
- **1) Resend** (recommended): then pick `1) API key` (uses HTTPS, simplest) or `2) SMTP` (uses port 587). Either way, paste your Resend API key (starts with `re_`).
- **2) Generic SMTP**: any provider — host, port, user, password, TLS mode (`starttls` for port 587, `tls` for port 465).
- **3) None**: alerts will be written to `/var/log/serverdeploy/alerts.log` and journald only.

#### Backblaze B2 backups
- **B2 bucket name** — leave empty if you don't want backups now (you can add them later).
- If filled in: bucket name + application key ID + application key.

The bootstrap then does its thing for ~5–10 minutes. You'll see colored `[INFO]`, `[OK]`, and `[WARN]` messages. At the end you should see:

```
[OK]    All stages complete.
```

You'll also receive a test email to confirm the relay works.

### Step 5: Test the new SSH port, then lock down port 22

From a **second** terminal (don't close the first one yet — it's your safety net):

```bash
ssh -p 2223 root@<your-server-ip>
# If this works, you're golden.
```

If that worked, **back in the original session**:

```bash
cd /root/serverdeploy
./bootstrap.sh --lock-ssh
```

This removes port 22 from sshd and the firewall. From now on you SSH on port 2223 only.

### Step 6: Verify backups (optional — only if you configured B2)

```bash
/usr/local/bin/backup.sh
tail /var/log/serverdeploy/backup.log
# Should end with: backup complete
```

---

## Part 2 — Adding sites

The single command for this is `newsite`:

```bash
newsite
```

It asks:

1. **Type:**
   - `1) Node.js` — generic Node app (Express, Fastify, raw HTTP)
   - `2) Next.js` — Next.js (single port, runs `npx next start`)
   - `3) PHP / WordPress / Laravel`

2. **Domain** — e.g. `example.com`. The script also asks if you want `www.example.com` to work (default yes).

3. **Database type:**
   - `none` — no database
   - `mariadb` — for WordPress / most PHP apps
   - `postgres` — for modern stacks

4. **For Node only — number of ports:**
   - `1` — single process (Next.js, monolithic Express). Easiest.
   - `2` — backend API + frontend UI on separate ports.

5. **For Node 2-port only — API exposure:**
   - `1) Subdirectory` — `https://example.com/api/*` goes to API; everything else goes to UI. One Caddy site, one cert.
   - `2) Subdomain` — `https://api.example.com/*` is its own site with its own cert; UI lives on the bare domain.

The script then creates:
- A Linux user named after your domain (e.g., `example-com`)
- A directory at `/srv/sites/example.com/`
- A database + DB user with a random 24-character password (which it shows you **once** — save it)
- A Caddy snippet at `/etc/caddy/sites/example.com.caddy`
- A `systemd` unit (Node) or PHP-FPM pool (PHP)
- An entry in `/etc/serverdeploy/sites/example.com.meta`

### After `newsite` finishes

#### For a Node site

1. Point DNS for the domain to the server.
2. Drop your code into `/srv/sites/<domain>/code/`. Make sure it's owned by the site user:
   ```bash
   chown -R example-com:example-com /srv/sites/example.com/code/
   ```
3. Create a `.env` file there with whatever your app needs (including `DATABASE_URL` from the password the script printed):
   ```bash
   sudo -u example-com vim /srv/sites/example.com/code/.env
   chmod 600 /srv/sites/example.com/code/.env
   ```
4. Run `npm install` and `npm run build` as the site user:
   ```bash
   sudo -u example-com bash -c 'cd /srv/sites/example.com/code && npm install && npm run build'
   ```
5. Open `/etc/systemd/system/example-com.service` and edit the `ExecStart=` line if your entry point isn't `index.js`. Common values:
   - Plain Node: `ExecStart=/usr/bin/node server.js`
   - Express with a build step: `ExecStart=/usr/bin/node dist/index.js`
   - Next.js (already pre-filled if you picked `2) Next.js`): `ExecStart=/usr/bin/npx next start -p 4001 -H 127.0.0.1`
6. Start it:
   ```bash
   systemctl daemon-reload
   systemctl enable --now example-com
   systemctl status example-com   # should be "active (running)"
   ```

#### For a PHP / WordPress site

1. Point DNS for the domain to the server.
2. Drop your code into `/srv/sites/<domain>/public/`. As the site user:
   ```bash
   cd /srv/sites/example.com/public
   sudo -u example-com curl -O https://wordpress.org/latest.tar.gz
   sudo -u example-com tar -xzf latest.tar.gz --strip-components=1
   rm latest.tar.gz
   chown -R example-com:caddy public/
   find public/ -type d -exec chmod 2750 {} \;
   find public/ -type f -exec chmod 640 {} \;
   ```
3. Visit `https://example.com/` in a browser to run the WordPress installer. The DB credentials the script printed are what you enter on the WordPress setup page.
4. After install, lock down `wp-config.php`:
   ```bash
   chmod 600 /srv/sites/example.com/public/wp-config.php
   ```

### Listing sites

```bash
listsite
```

Shows a table with each site's type, ports, DB, service status, and creation date.

### Removing a site

```bash
delsite
# Pick from the numbered list, type the domain to confirm.
```

Everything (files, configs, DB, systemd units, FPM pool, mail domain) is archived to `/srv/backups/archived/<domain>-<timestamp>.tar.gz` (kept 7 days) before being deleted.

### Restoring a site from an archive

```bash
restoresite
# Pick from numbered list. Re-creates user, DB, configs, and re-imports the
# latest matching DB dump from /srv/backups/dumps/.
```

---

## Part 3 — Day-to-day operations

### Giving someone SSH access to a single site (without giving them the whole server)

Two modes: **SFTP-only** (locked into the site folder, no shell) or **shell** (full bash but only inside the site).

```bash
# SFTP-only (default — safest)
siteuser add example.com alice --key /tmp/alice.pub

# Shell access (so they can run npm install, composer, etc.)
siteuser add example.com bob --shell --key /tmp/bob.pub

# List who has access
siteuser list example.com

# Remove
siteuser del example.com bob
```

Shell users get a sudoers rule that lets them `systemctl restart`, `systemctl status`, and `journalctl` only their own site's units — nothing else. They cannot `sudo` anything else.

### Managing the admin IP allowlist

This controls who can reach `mail.<host>`, `pma.<host>`, and `pga.<host>`. All three share the same list.

```bash
adminip list                       # see current allowlist
adminip allow 203.0.113.7          # add an IP
adminip allow 2001:db8::/32        # IPv6 / CIDR also work
adminip remove 203.0.113.7         # exact match
adminip remove                     # no arg → numbered list, pick a number
adminip allow-all                  # opens admin to the whole internet (asks for "YES" confirmation)
```

Every change is validated with `caddy validate` before applying. If it would break Caddy, the change is rolled back automatically. Audit log: `/var/log/serverdeploy/adminip.log`.

### Managing the country block (GeoIP)

Default mode is "block listed countries, allow everything else." The list is set at install but you can change it any time:

```bash
geoblock status                          # current settings
geoblock countries list                  # see country codes
geoblock countries add IR                # add Iran
geoblock countries remove RU             # un-block Russia
geoblock countries set RU,CN,KP          # replace whole list

# Let one specific IP through despite their country being blocked:
geoblock bypass add 203.0.113.99
geoblock bypass list
geoblock bypass remove                   # numbered prompt
geoblock bypass remove 203.0.113.99      # exact match

# Disable geoblock for one specific site (e.g., a site that needs Chinese visitors):
geoblock disable example.com
geoblock enable example.com

# Switch to "default-deny, only allow listed countries" — very strict
geoblock mode allow
geoblock mode block                      # back to default
```

If a site sits behind Cloudflare/Fastly/Akamai/CloudFront/Bunny/Sucuri/StackPath, Caddy unwraps the CDN's `X-Forwarded-For` header so the country block evaluates the real visitor IP, not the CDN edge. The CDN list is refreshed automatically every Sunday.

### Tuning the WAF (when it blocks something legitimate)

```bash
waf-whitelist
# 1) Disable a rule for one site
# 2) Disable a rule globally
# 3) Bypass WAF entirely for one IP (admin convenience)
# 4) Disable a rule on a specific path (e.g. /wp-admin/admin-ajax.php)
```

To find which rule fired (so you know what number to disable):

```bash
grep 'Access denied' /var/log/caddy/coraza-audit.log | tail -20
# Look for "id" fields like 942100, 920170, etc.
```

### Adding a mail domain for a client

The mail server (Stalwart) handles inbound mail for any domain you tell it about. When you ran `newsite`, it asked "Add mail domain?" — if you said yes, it printed the DNS records to publish. If you said no and want to add it later:

1. Open `https://mail.<your-host>/login` (you'll need to be on an allowlisted IP — check with `adminip list`)
2. Login with the password from `/etc/serverdeploy/stalwart-admin.txt`
3. Add the domain through the Stalwart UI. It will generate a DKIM key.
4. Publish these DNS records at the registrar:
   - **MX** for `<domain>` → `10 srv1.example.com.`
   - **TXT** for `<domain>` → `v=spf1 a:srv1.example.com -all`
   - **TXT** for `_dmarc.<domain>` → `v=DMARC1; p=quarantine; rua=mailto:you@example.com`
   - **TXT** for `default._domainkey.<domain>` → (DKIM public key from Stalwart UI)

Then add user mailboxes through the Stalwart UI.

### Reading alert emails / logs

Alerts arrive with a subject like `[Alert on srv1] CPU at 92% sustained 5m`. They tell you:
- What's wrong
- The actual measurement
- A snapshot of the situation (top processes, disk usage, etc.)

Each alert type has a 15-minute cooldown — once it fires, it won't re-fire for 15 minutes even if the condition persists. When the condition recovers, you get a "RECOVERED" email.

Logs to know:

| Log | What's in it |
|---|---|
| `journalctl -u caddy -f` | Caddy live |
| `journalctl -u <site-name> -f` | Live output of a Node site's systemd unit |
| `tail -f /srv/sites/<domain>/logs/*.log` | App-level logs |
| `tail -f /var/log/caddy/<domain>.log` | Per-site access log |
| `tail -f /var/log/caddy/coraza-audit.log` | WAF blocks (look here when something legitimate gets blocked) |
| `tail -f /var/log/serverdeploy/health.log` | Per-minute health check trace |
| `tail -f /var/log/serverdeploy/alerts.log` | All alerts that fired |
| `tail -f /var/log/serverdeploy/backup.log` | Last night's backup run |
| `cscli decisions list` | Currently banned IPs |
| `cscli alerts list` | Recent attacks CrowdSec saw |

---

## Part 4 — When something goes wrong

### A site is returning 502 Bad Gateway

Means Caddy can't reach the upstream service.

```bash
systemctl status example-com           # is the systemd unit running?
journalctl -u example-com -n 50        # last 50 lines of its output
ss -tlnp | grep 4001                   # is anything actually listening on the port?
```

Most common causes: app crashed (read its journal), wrong port (check `/etc/systemd/system/example-com.service`), or `npm install`/`npm run build` was never run.

### A site is returning 403 Forbidden

Could be:
- **WAF block** — check `/var/log/caddy/coraza-audit.log`. If your own request is being blocked, use `waf-whitelist` option 3 to bypass for your IP, or option 4 to disable the rule on a specific path.
- **GeoIP block** — check what country your IP resolves to. Use `geoblock bypass add <your-ip>` to whitelist yourself.
- **Admin allowlist** — admin endpoints (mail/pma/pga) reject anyone not in `MAIL_ADMIN_ALLOWLIST`. Use `adminip list` to check, `adminip allow <ip>` to add yourself.

### Caddy won't start / won't reload

```bash
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
# Read the error. It points to the line.

journalctl -u caddy -n 50
```

If you just edited a site file and broke it, fix the file or `rm` it and `systemctl reload caddy`.

### "I locked myself out of the admin panel"

If your IP changed and you can't reach `mail.<host>` / `pma.<host>` / `pga.<host>` anymore, SSH in (you still have SSH) and run:

```bash
adminip allow <your-new-ip>
```

### Database connection refused

```bash
systemctl status mariadb        # or postgresql-16
ss -tlnp | grep -E '3306|5432'  # both should show 127.0.0.1 only
```

Both bind to localhost only; this is intentional. Apps connect via `127.0.0.1:3306` (MariaDB) or `127.0.0.1:5432` (Postgres).

### CrowdSec is banning a legitimate IP

```bash
cscli decisions list                            # see all bans
cscli decisions delete --ip 1.2.3.4             # unban
cscli decisions add --ip 1.2.3.4 --type whitelist  # add to allowlist
```

### "I changed my mind about the install — can I rerun a stage?"

Yes. Each bootstrap stage is idempotent (safe to run repeatedly). Examples:

```bash
./bootstrap.sh 35-tools.sh        # add/remove phpMyAdmin or pgAdmin4 (after editing /etc/serverdeploy/config)
./bootstrap.sh 45-geoip.sh        # change GeoIP source or country list (geoblock cmd is faster)
./bootstrap.sh 50-backups.sh      # re-install backup script after editing config
./bootstrap.sh 60-monitoring.sh   # change health check thresholds (edit /usr/local/bin/health-check.sh)
```

To resume from a stage if a previous run crashed:

```bash
./bootstrap.sh --resume-from 40-crowdsec.sh
```

---

## Part 5 — File layout reference

```
/srv/sites/<domain>/
    code/        Node source (chown <user>:<user>)
    public/      PHP docroot (chown <user>:caddy, mode 2750/640)
    private/     Out-of-docroot PHP files (PHP-only)
    data/        Runtime data, sessions
    logs/        App logs, PHP error log

/etc/caddy/Caddyfile                    Main config
/etc/caddy/sites/*.caddy                Per-site
/etc/caddy/snippets/                    Shared Caddy snippets
    trusted_cdn.caddy                   CDN CIDRs (auto-refreshed)
    geoblock.caddy                      Country block (auto-rendered by geoblock cmd)
/etc/caddy/coraza/                      WAF
    coraza.conf                         Baseline directives
    whitelist.conf                      Global rule exclusions
    sites/<domain>.conf                 Per-site rule exclusions
    crs/                                OWASP Core Rule Set
    .next-id                            Counter for waf-whitelist

/etc/serverdeploy/
    config                              All your settings + secrets (mode 600)
    port-pool                           Port allocation (4000-5000)
    sites/<domain>.meta                 Per-site metadata
    sites/<domain>.users                Site SSH users
    restic.password                     Backup encryption key (BACK THIS UP OFFLINE)
    stalwart-admin.txt                  Mail server admin password
    mail-basic-auth.txt                 Caddy basic-auth for mail.<host>
    pma-basic-auth.txt                  phpMyAdmin Caddy basic-auth
    pgadmin-admin.txt                   pgAdmin4 first-login email + password
    pgadmin-basic-auth.txt              pgAdmin4 Caddy basic-auth

/var/lib/serverdeploy/
    alerts/<key>.state                  Alert cooldown state files
    cpu/                                CPU sustained-breach tracking
    last-backup                         Last successful backup timestamp

/var/log/serverdeploy/                  All serverdeploy logs (rotated weekly)
/var/log/caddy/                         Caddy access + WAF logs (rotated daily)

/srv/backups/dumps/                     Nightly DB exports
/srv/backups/archived/                  delsite archives (kept 7 days)
```

---

## Part 6 — Command cheat sheet

| Command | Purpose |
|---|---|
| `newsite` | Add a new site |
| `delsite` | Remove a site (with archive) |
| `restoresite` | Bring back a deleted site |
| `listsite` | Show all sites |
| `siteuser add\|del\|list <domain> [<user>]` | Per-site SSH users |
| `adminip list\|allow\|remove\|allow-all` | Admin endpoint IP allowlist |
| `geoblock status\|countries\|bypass\|disable\|enable\|mode` | Country block |
| `waf-whitelist` | Tune Coraza/CRS rules |
| `update-caddy` | Pull the latest Caddy build |
| `stalwart-passwd <new>` | Change the Stalwart admin password |
| `/usr/local/bin/backup.sh` | Run a backup right now |
| `/usr/local/bin/health-check.sh` | Run health checks right now |
| `cscli decisions list` | See banned IPs |
| `cscli decisions delete --ip <ip>` | Unban an IP |

---

## Part 7 — Things to do once a quarter

- Check `restic snapshots` and `restic check` (run manually) to be sure backups are restorable
- Try a test restore of one snapshot to a tmp dir: `restic restore latest --target /tmp/restore-test --include /srv/sites/example.com`
- Open `/etc/serverdeploy/config`, confirm secrets are correct, rotate any that have leaked
- Update the OS: `dnf -y upgrade --refresh && reboot` (off-hours)
- Update Caddy: `update-caddy` (also runs monthly via cron)
- Update OWASP CRS: runs automatically every quarter, but you can force it: `/usr/local/bin/serverdeploy-crs-refresh`
- Refresh MaxMind mmdb (offline mode only — API mode auto-updates weekly): drop new files, run `./bootstrap.sh 45-geoip.sh`

---

## Part 8 — Security posture in one diagram

```
Internet
  |
  +-- firewalld (default deny: <SSH_PORT>, 80, 443, 443/udp, 25, 465, 587, 993)
  |
  +-- CrowdSec (parsers: ssh, caddy, http-bf, http-probing, http-sensitive-files, geoip)
  |     → nftables firewall bouncer (bans at the firewall layer)
  |
  +-- Caddy + Coraza WAF (OWASP CRS, paranoia 1)
  |     + secure_headers (HSTS preload, nosniff, frame-deny, ...)
  |     + GeoIP block (with per-IP bypass)
  |     + trusted_proxies for major CDNs (real client IP enforcement)
  |     + admin endpoints: IP allowlist + HTTP basic auth + rate limit
  |
  +-- Per-tenant isolation
  |     - Linux user per site, group-writable site dir (2770)
  |     - per-tenant DB user with locked-down privileges
  |     - PHP open_basedir sandbox + dangerous functions disabled
  |     - systemd hardening (NoNewPrivileges, ProtectSystem, RestrictAddressFamilies, MemoryMax)
  |     - per-site SSH users via siteuser (sftp-chroot default, --shell opt-in)
  |
  +-- ClamAV + maldet (daily scan, auto-quarantine)
  +-- rkhunter (weekly rootkit scan)
  +-- SSH key-only, custom port, modern KEX/cipher/MAC
  +-- dnf-automatic security patches
  +-- restic encrypted backups → B2 (with key-list change detection)
```

---

## Part 9 — Getting unstuck

If you hit something this README doesn't cover:

1. Check `journalctl -xe` and the relevant log file from Part 3
2. Re-read the relevant `bootstrap/*.sh` — they're meant to be human-readable
3. The configuration is **always** in `/etc/serverdeploy/config` — start there
4. Every script in this repo is idempotent — re-running a stage won't break things, it'll just reapply settings

When in doubt: **don't delete things you don't understand.** Move them aside (`mv foo foo.bak`) so you can put them back.

Good luck. The whole point of this stack is that you can fit the mental model in your head — once you've added one site, you've seen 90% of how it works.
