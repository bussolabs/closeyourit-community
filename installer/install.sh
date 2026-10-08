#!/usr/bin/env bash
#
# Installs CloseYourIt on this server (CYRA-919):
#
#   curl -fsSL https://get.closeyour.it | sudo bash
#
# Asks for a domain, an email for the certificate, the administrator email and (optionally) an
# SMTP server; writes /opt/closeyourit with freshly generated secret keys; starts app, worker,
# PostgreSQL and Caddy; turns on the nightly backup. Prints the administrator password once.
#
# Non-interactive use: set DOMAIN, ACME_EMAIL, ADMIN_EMAIL (and SMTP_* if wanted) beforehand.
# CLOSEYOURIT_VERSION picks a version; the default is the latest release.
# A mirror can stand in for GitHub: CLOSEYOURIT_RELEASES_API, CLOSEYOURIT_RELEASES_RAW and
# CLOSEYOURIT_IMAGE, kept in .env for updates. CLOSEYOURIT_SKILLS_RELEASES_API does the same
# for the cyi skills releases.
set -euo pipefail

REPO="bussolabs/closeyourit-community"
HOME_DIR="${CLOSEYOURIT_HOME:-/opt/closeyourit}"
RELEASES_API="${CLOSEYOURIT_RELEASES_API:-https://api.github.com/repos/$REPO}"
RELEASES_RAW="${CLOSEYOURIT_RELEASES_RAW:-https://raw.githubusercontent.com/$REPO}"

say() { printf '%s\n' "$*"; }
fail() { printf '\nCloseYourIt installer: %s\n' "$*" >&2; exit 1; }

# The script usually arrives through a pipe: questions are read from the terminal, not stdin.
ask() {
  local prompt="$1" default="${2:-}" answer
  # No terminal (cloud-init, CI, ssh without -t): take the default without asking.
  if ! { : > /dev/tty; } 2>/dev/null; then printf '%s' "$default"; return; fi
  if [ -n "$default" ]; then prompt="$prompt [$default]"; fi
  printf '%s: ' "$prompt" > /dev/tty
  read -r answer < /dev/tty || true
  printf '%s' "${answer:-$default}"
}

random_hex() { openssl rand -hex "$1"; }
random_alnum() { openssl rand -base64 64 | tr -dc 'A-Za-z0-9' | head -c "$1"; }

admin_password() {
  # Upper, lower, digit and symbol: the account password rule of the app.
  printf '%s%s' "$(random_alnum 18)" "aZ7!"
}

# Everything runs inside main, called on the last line: through `curl | bash` the shell reads the
# whole script before running it, so a command that reads stdin cannot swallow the rest of it.
main() {
[ "$(id -u)" -eq 0 ] || fail "run it as root (sudo bash)"
[ "$(uname -s)" = "Linux" ] || fail "Linux only"
case "$(uname -m)" in x86_64|aarch64|arm64) ;; *) fail "unsupported CPU: $(uname -m)";; esac
command -v curl >/dev/null || fail "curl is missing"
command -v openssl >/dev/null || fail "openssl is missing"
[ ! -e "$HOME_DIR/.env" ] || fail "$HOME_DIR already has an install: use 'closeyourit update'"

say "CloseYourIt installer"
say ""

if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
  answer="$(ask "Docker with the compose plugin is missing. Install it now? (y/n)" "y")"
  [ "$answer" = "y" ] || fail "Docker is required"
  curl -fsSL https://get.docker.com | sh
fi

DOMAIN="${DOMAIN:-$(ask "Domain for CloseYourIt (for example bugs.example.com)")}"
[ -n "$DOMAIN" ] || fail "a domain is required"
ACME_EMAIL="${ACME_EMAIL:-$(ask "Email for the HTTPS certificate")}"
ADMIN_EMAIL="${ADMIN_EMAIL:-$(ask "Administrator email" "$ACME_EMAIL")}"
SMTP_ADDRESS="${SMTP_ADDRESS:-$(ask "SMTP server (empty to skip for now)")}"
if [ -n "$SMTP_ADDRESS" ]; then
  SMTP_PORT="${SMTP_PORT:-$(ask "SMTP port" "587")}"
  SMTP_USERNAME="${SMTP_USERNAME:-$(ask "SMTP username")}"
  SMTP_PASSWORD="${SMTP_PASSWORD:-$(ask "SMTP password")}"
  MAIL_FROM="${MAIL_FROM:-$(ask "Sender" "CloseYourIt <noreply@$DOMAIN>")}"
fi

server_ip="$(curl -fsS4 https://api.ipify.org 2>/dev/null || true)"
domain_ip="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1 {print $1}' || true)"
if [ -n "$server_ip" ] && [ "$server_ip" != "$domain_ip" ]; then
  say ""
  say "warning: $DOMAIN points to ${domain_ip:-nothing}, this server is $server_ip."
  say "The HTTPS certificate is issued only once the domain points here."
fi

VERSION="${CLOSEYOURIT_VERSION:-$(curl -fsSL "$RELEASES_API/releases/latest" | sed -nE 's/.*"tag_name": *"v?([^"]+)".*/\1/p' | head -1)}"
VERSION="${VERSION#v}"
[ -n "$VERSION" ] || fail "could not read the latest version from GitHub"

say ""
say "→ downloading CloseYourIt $VERSION files"
mkdir -p "$HOME_DIR/backups" "$HOME_DIR/ingest"
# Before the first start, or Docker creates them owned by root and the app cannot leave a request.
install -d -m 755 "$HOME_DIR/updates" "$HOME_DIR/updates/status"
install -d -m 755 -o 1000 -g 1000 "$HOME_DIR/updates/inbox"
raw="$RELEASES_RAW/v$VERSION/installer"
for file in compose.yml Caddyfile initdb.sql nats.conf closeyourit; do
  curl -fsSL "$raw/$file" -o "$HOME_DIR/$file.download"
done
mv "$HOME_DIR/nats.conf.download" "$HOME_DIR/ingest/nats.conf"
for file in compose.yml Caddyfile initdb.sql; do mv "$HOME_DIR/$file.download" "$HOME_DIR/$file"; done
install -m 755 "$HOME_DIR/closeyourit.download" /usr/local/bin/closeyourit
rm -f "$HOME_DIR/closeyourit.download"

say "→ generating secret keys"
ADMIN_PASSWORD="$(admin_password)"
nats_password="$(random_alnum 32)"
umask 077
cat > "$HOME_DIR/.env" <<EOF
# CloseYourIt settings. After a change: closeyourit restart
CLOSEYOURIT_VERSION=$VERSION
DOMAIN=$DOMAIN
ACME_EMAIL=$ACME_EMAIL
APP_HOSTS=$DOMAIN
MAIL_HOST=$DOMAIN
MAIL_FROM=${MAIL_FROM:-CloseYourIt <noreply@$DOMAIN>}
SMTP_ADDRESS=${SMTP_ADDRESS:-}
SMTP_PORT=${SMTP_PORT:-587}
SMTP_USERNAME=${SMTP_USERNAME:-}
SMTP_PASSWORD=${SMTP_PASSWORD:-}
GOD_EMAIL=$ADMIN_EMAIL
GOD_PASSWORD=$ADMIN_PASSWORD

# Generated at install time. Losing them means losing the encrypted data, and the database backups
# do not contain them: keep a copy of this file somewhere safe.
POSTGRES_PASSWORD=$(random_alnum 40)
SECRET_KEY_BASE=$(random_hex 64)
AR_ENCRYPTION_PRIMARY_KEY=$(random_alnum 32)
AR_ENCRYPTION_DETERMINISTIC_KEY=$(random_alnum 32)
AR_ENCRYPTION_KEY_DERIVATION_SALT=$(random_alnum 32)
SECRET_ASSETS_MASTER_KEY=$(openssl rand -base64 32)

# Optional: uploads on S3 instead of the disk, and a copy of each backup on S3.
AWS_S3_BUCKET=
AWS_REGION=
AWS_ACCESS_KEY_ID=
AWS_SECRET_ACCESS_KEY=
BACKUP_S3_BUCKET=

# Ingest gateway (closeyourit enable ingest).
INGEST_ENABLED=false
INGEST_UPSTREAM=app:80
EOF
for key in CLOSEYOURIT_RELEASES_API CLOSEYOURIT_RELEASES_RAW CLOSEYOURIT_IMAGE CLOSEYOURIT_SKILLS_RELEASES_API; do
  if [ -n "${!key:-}" ]; then printf '%s=%s\n' "$key" "${!key}" >> "$HOME_DIR/.env"; fi
done
printf '%s' "$nats_password" > "$HOME_DIR/ingest/nats_password"
printf 'NATS_PASSWORD=%s\n' "$nats_password" > "$HOME_DIR/ingest/nats.env"
openssl rand -base64 32 | tr -d '\n' > "$HOME_DIR/ingest/envelope_key"
umask 022

say "→ starting app, worker, PostgreSQL and Caddy (the first start takes a few minutes)"
cd "$HOME_DIR"
docker compose pull --quiet
docker compose up -d

say "→ waiting for the app"
for _ in $(seq 1 100); do
  if docker compose exec -T app curl -fsS -o /dev/null http://localhost/up 2>/dev/null; then break; fi
  sleep 3
done
docker compose exec -T app curl -fsS -o /dev/null http://localhost/up 2>/dev/null \
  || fail "the app did not start; see: cd $HOME_DIR && docker compose logs app"

# The administrator exists now: its password must not stay written in the settings.
sed -i '/^GOD_PASSWORD=/d' "$HOME_DIR/.env"

say "→ nightly backup at 03:00 (the last 7 are kept)"
cat > /etc/cron.d/closeyourit <<'EOF'
0 3 * * * root /usr/local/bin/closeyourit backup >> /var/log/closeyourit-backup.log 2>&1
EOF

say "→ updates from the app (Administration, Update now)"
# Releases older than CYRA-1035 lack the command: the install goes on without the button.
/usr/local/bin/closeyourit enable updates > /dev/null 2>&1 || say "  not in this version: later, closeyourit update && closeyourit enable updates"

say ""
say "✔ CloseYourIt $VERSION is running"
say ""
say "  Address:  https://$DOMAIN"
say "  Email:    $ADMIN_EMAIL"
say "  Password: $ADMIN_PASSWORD"
say ""
say "Write the password down now: it is not shown again."
say "Sign in, set up the second factor, then create your first organization in Administration."
say "Commands: closeyourit status | update | backup | doctor"
}

main "$@"
