#!/usr/bin/env bash
# One-command deploy for the whole stack on a fresh Ubuntu VM.
# Idempotent: safe to re-run. Wraps the README "Quick Start" so an engineer
# doesn't have to copy/paste a dozen commands (and can't skip the firewall).
#
# Steps: dependencies -> /opt/service-env layout -> serviceenv user -> venv ->
#        /etc/hosts discovery -> firewall -> systemd units -> Nginx -> smoke test.
#
# Usage:
#   sudo ./scripts/install.sh

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    echo "This installer must be run as root. Try: sudo $0" >&2
    exit 1
fi

# Resolve repo root from this script's location, so it works from any CWD.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_ROOT="/opt/service-env"
cd "$REPO_ROOT"

echo "==> [1/8] Installing OS dependencies"
apt-get update -qq
apt-get install -y -qq python3-venv nginx curl

echo "==> [2/8] Laying out $APP_ROOT"
mkdir -p "$APP_ROOT"
cp -r services requirements.txt "$APP_ROOT/"

echo "==> [3/8] Creating the serviceenv system user"
useradd --system --no-create-home --shell /usr/sbin/nologin serviceenv 2>/dev/null \
    || echo "    serviceenv already exists, skipping"

echo "==> [4/8] Building the shared virtualenv + installing deps"
[[ -d "$APP_ROOT/venv" ]] || python3 -m venv "$APP_ROOT/venv"
"$APP_ROOT/venv/bin/pip" install -q --upgrade pip
"$APP_ROOT/venv/bin/pip" install -q -r "$APP_ROOT/requirements.txt"
chown -R serviceenv:serviceenv "$APP_ROOT"

echo "==> [5/8] Service discovery (/etc/hosts)"
"$REPO_ROOT/scripts/hosts-setup.sh"

echo "==> [6/8] Firewall (ufw: only 22 + 80 inbound)"
"$REPO_ROOT/scripts/firewall-setup.sh"

echo "==> [7/8] Installing + enabling systemd units"
cp systemd/service-*.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now service-b service-c service-a

echo "==> [8/8] Deploying Nginx"
rm -f /etc/nginx/sites-enabled/default /etc/nginx/conf.d/default.conf
cp nginx/service-env.conf /etc/nginx/conf.d/service-env.conf
nginx -t
systemctl reload nginx

echo
echo "==> Deploy complete. Running smoke test:"
"$REPO_ROOT/scripts/test-end-to-end.sh"
