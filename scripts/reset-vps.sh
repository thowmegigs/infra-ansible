#!/usr/bin/env bash
# ===========================================================================
# reset-vps.sh — wipe the existing (manually-deployed) stack so the Ansible
# playbooks can be tested from a clean slate.
#
#   LIGHT reset (default): removes app state, keeps packages installed.
#       sudo ./reset-vps.sh
#
#   FULL wipe: also apt-purges nginx/mysql/php/node/redis/certbot.
#       sudo ./reset-vps.sh --full
#
# A backup (DB dump + /var/www tarball) is ALWAYS taken first.
# You must type CONFIRM to proceed.
# ===========================================================================
set -euo pipefail

MODE="light"
[[ "${1:-}" == "--full" ]] && MODE="full"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root (sudo)." >&2
  exit 1
fi

# --- Items specific to this stack (keep in sync with production.yml) --------
PROJECT_DIRS=(
  /var/www/front
  /var/www/admin
  /var/www/api
  /var/www/seller
  /var/www/scripts
  /var/www/image-to-product
  /var/www/ecosystem.config.js
)
PYTHON_VENV=/home/devuser/fashion-ai
NGINX_SITES=(front admin api seller_front seller_backend phpmyadmin)
SYSTEMD_SERVICES=(image-analysis-service product-textinfo-generator-service)
DB_NAME=colourindigo

echo "=== reset-vps.sh — mode: ${MODE^^} ==="
echo "This will DELETE the running stack on THIS server."
read -r -p "Type CONFIRM to continue: " ans
[[ "$ans" == "CONFIRM" ]] || { echo "Aborted."; exit 1; }

# --- 0. Backup --------------------------------------------------------------
TS="$(date +%Y%m%d-%H%M%S)"
BK="/root/pre-reset-backup-$TS"
mkdir -p "$BK"
echo ">>> Backing up to $BK"
if command -v mysqldump >/dev/null 2>&1; then
  mysqldump --all-databases > "$BK/all-databases.sql" 2>/dev/null \
    || echo "    (mysqldump skipped — could not connect)"
fi
[[ -d /var/www ]] && tar czf "$BK/var-www.tar.gz" -C / var/www 2>/dev/null || true
[[ -d /etc/letsencrypt ]] && tar czf "$BK/letsencrypt.tar.gz" -C / etc/letsencrypt 2>/dev/null || true
echo ">>> Backup done."

# --- 1. PM2 -----------------------------------------------------------------
echo ">>> Removing PM2 processes"
if command -v pm2 >/dev/null 2>&1; then
  pm2 delete all 2>/dev/null || true
  pm2 save --force 2>/dev/null || true
  pm2 unstartup systemd 2>/dev/null || true
  pm2 kill 2>/dev/null || true
fi
rm -f /etc/systemd/system/pm2-root.service

# --- 2. Python systemd services --------------------------------------------
echo ">>> Removing python systemd services"
for svc in "${SYSTEMD_SERVICES[@]}"; do
  systemctl stop "$svc" 2>/dev/null || true
  systemctl disable "$svc" 2>/dev/null || true
  rm -f "/etc/systemd/system/${svc}.service"
done
systemctl daemon-reload

# --- 3. nginx vhosts --------------------------------------------------------
echo ">>> Removing nginx vhosts"
for site in "${NGINX_SITES[@]}"; do
  rm -f "/etc/nginx/sites-enabled/${site}.conf" "/etc/nginx/sites-available/${site}.conf"
  # also clean any non-.conf names a manual setup might have used
  rm -f "/etc/nginx/sites-enabled/${site}"      "/etc/nginx/sites-available/${site}"
done
if command -v nginx >/dev/null 2>&1; then
  nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
fi

# --- 4. Project code + venv -------------------------------------------------
echo ">>> Removing project directories"
for d in "${PROJECT_DIRS[@]}"; do
  rm -rf "$d"
done
rm -rf "$PYTHON_VENV"

# --- 5. Database ------------------------------------------------------------
echo ">>> Dropping database $DB_NAME"
if command -v mysql >/dev/null 2>&1; then
  mysql -e "DROP DATABASE IF EXISTS \`$DB_NAME\`;" 2>/dev/null \
    || echo "    (could not drop DB — drop it manually if needed)"
fi

# --- 6. Optional full wipe --------------------------------------------------
if [[ "$MODE" == "full" ]]; then
  echo ">>> FULL wipe: stopping GlitchTip containers"
  if command -v docker >/dev/null 2>&1 && [[ -f /opt/glitchtip/docker-compose.yml ]]; then
    ( cd /opt/glitchtip && docker compose down -v 2>/dev/null ) || true
  fi
  rm -rf /opt/glitchtip

  echo ">>> FULL wipe: purging packages"
  systemctl stop nginx mysql redis-server opensearch \
    grafana-server loki promtail prometheus node_exporter \
    redis_exporter mysqld_exporter nginx_exporter \
    process_exporter blackbox_exporter pm2-metrics.timer 2>/dev/null || true
  rm -f  /etc/systemd/system/{process_exporter,blackbox_exporter}.service
  rm -f  /usr/local/bin/{process-exporter,blackbox_exporter}
  rm -rf /etc/process-exporter /etc/blackbox_exporter
  # observability (binaries + systemd units + data)
  apt-get purge -y grafana 2>/dev/null || true
  rm -f  /etc/systemd/system/{loki,promtail,prometheus,node_exporter}.service
  rm -f  /etc/systemd/system/{redis_exporter,mysqld_exporter,nginx_exporter}.service
  rm -f  /etc/systemd/system/pm2-metrics.{service,timer}
  rm -f  /usr/local/bin/{loki,promtail,prometheus,promtool,node_exporter}
  rm -f  /usr/local/bin/{redis_exporter,mysqld_exporter,prometheus-nginxlog-exporter,pm2-metrics.sh}
  rm -rf /etc/loki /var/lib/loki /etc/promtail /var/lib/promtail \
         /etc/prometheus /var/lib/prometheus /etc/grafana /var/lib/grafana \
         /etc/mysqld_exporter /etc/nginx_exporter /var/lib/node_exporter
  systemctl daemon-reload 2>/dev/null || true
  apt-get purge -y \
    nginx nginx-common nginx-core \
    mysql-server mysql-client mysql-common \
    'php8.*' \
    nodejs \
    redis-server \
    opensearch \
    certbot python3-certbot-nginx 2>/dev/null || true
  apt-get autoremove -y || true
  rm -rf /var/lib/mysql /etc/mysql
  rm -rf /etc/letsencrypt
  rm -rf /usr/share/phpmyadmin
  rm -rf /etc/nginx
  rm -rf /etc/opensearch /var/lib/opensearch /var/log/opensearch
  rm -f  /usr/local/bin/composer /usr/local/bin/pm2 /usr/lib/node_modules/pm2
  rm -f  /etc/apt/sources.list.d/nodesource.list /etc/apt/sources.list.d/opensearch.list
  echo ">>> Packages purged. bootstrap.yml will reinstall everything."
fi

echo
echo "=== Reset complete (mode: ${MODE^^}). Backup at: $BK ==="
echo "Now run:"
echo "  cd /path/to/infra-ansible"
echo "  ansible-galaxy collection install -r requirements.yml"
echo "  ansible-playbook -i inventory/local.ini site.yml"
