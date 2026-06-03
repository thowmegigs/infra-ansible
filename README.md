# infra-ansible

Idempotent Ansible automation that provisions and deploys the full **colourindigo**
VPS stack on **Ubuntu 24.04 LTS**. Ansible runs **locally on the VPS** (no SSH from a
control machine).

It supports first-time provisioning, repeat deployments, disaster recovery, and
bringing a brand-new VPS up from scratch with a single command.

```bash
ansible-playbook -i inventory/local.ini site.yml
```

> 📖 For the exact step-by-step run procedure on the VPS, see **[RUNBOOK.md](RUNBOOK.md)**.

---

## What gets installed & configured

| Layer        | Details                                                                 |
|--------------|-------------------------------------------------------------------------|
| Base system  | git, curl, unzip, nginx, certbot                                        |
| Node.js      | Node 20.20.1 (NodeSource, pinned) + npm + **PM2** (global)             |
| PHP          | php8.2 (fpm/cli/mysql + extensions) + **Composer**                     |
| Database     | MySQL server + application databases/users                             |
| Cache        | Redis (enabled + started)                                              |
| Search       | OpenSearch (Apache-2.0, localhost `:9200`, single-node)                |
| Python       | python3 / pip / venv + per-service **systemd** units                   |
| Web          | nginx vhosts for every production domain                               |
| TLS          | Let's Encrypt certificates via certbot (production domains only)       |
| Secrets      | centralized `/opt/secrets/*.env` (root-only) from `env/` + vault       |
| Logging      | Loki + Promtail (log aggregation, localhost)                          |
| Monitoring   | Node/Redis/MySQL/Nginx/Process/Blackbox exporters + Prometheus + Grafana|
| Alerting     | Grafana alert rules + email (crash / uptime / resource / app errors)  |
| Error report | GlitchTip (self-hosted, Sentry-compatible, Docker)                    |

---

## Repository layout

```text
ansible.cfg                 # inventory + role paths, become defaults
requirements.yml            # galaxy collections (community.mysql, etc.)
site.yml                    # master playbook (imports everything in order)

inventory/local.ini         # [local] localhost ansible_connection=local
group_vars/
├── all.yml                 # global config: versions, nginx_sites, pm2_apps, mysql_*
└── production.yml          # projects + experimental_projects (source of truth)

playbooks/
├── bootstrap.yml  → roles: common, node, php
├── secrets.yml    → role:  secrets
├── mysql.yml      → role:  mysql
├── redis.yml      → role:  redis
├── opensearch.yml → role:  opensearch
├── phpmyadmin.yml → role:  phpmyadmin
├── deploy.yml     → roles: deploy, python
├── pm2.yml        → role:  pm2
├── nginx.yml      → role:  nginx
├── ssl.yml        → role:  ssl
├── logging.yml    → roles: loki, promtail, logrotate
├── monitoring.yml → roles: node/redis/mysqld/nginx/process/blackbox exporters, prometheus, grafana, alerting
├── glitchtip.yml  → role:  glitchtip
└── backup.yml     → role:  backup   (optional, not in site.yml)

roles/
├── common/   base packages, deploy user, nginx
├── node/     Node.js + PM2
├── php/      PHP 8.2 + Composer
├── mysql/    MySQL + databases/users
├── redis/    Redis
├── opensearch/ OpenSearch (Apache-2.0 search engine)
├── secrets/  copy env/ -> /opt/secrets (root-only)
├── loki/       central log store
├── promtail/   log collector
├── logrotate/  app log rotation
├── node_exporter/ host metrics + systemd + pm2 textfile
├── redis_exporter/  redis metrics
├── mysqld_exporter/ mysql metrics
├── nginx_exporter/  nginx log metrics
├── process_exporter/ per-process crash detection
├── blackbox_exporter/ uptime/HTTP/TLS probes
├── prometheus/ metrics store
├── grafana/    dashboards + datasources
├── alerting/   Grafana alert rules + email contact point
├── glitchtip/  self-hosted error reporting (Docker)
├── deploy/   clone/pull + build every project (incl. monorepo)
├── python/   python venv + systemd units for AI services
├── pm2/      ecosystem.config.js + process management
├── nginx/    production vhosts
├── ssl/      certbot certificates
└── backup/   mysqldump + web-root archive

templates/
├── ecosystem.config.js.j2  # PM2 apps
├── nginx-site.j2           # proxy (Next.js/Express) + php (Laravel)
└── python-service.j2       # systemd unit for python services
```

---

## 1. First VPS setup

On a fresh Ubuntu 24.04 VPS, as **root** (or a sudo user):

```bash
# 1. Install Ansible + git
apt update && apt install -y ansible git

# 2. Clone this repository
git clone <this-repo-url> infra-ansible
cd infra-ansible

# 3. Install required Ansible collections
ansible-galaxy collection install -r requirements.yml

# 4. Add an SSH deploy key that can read the GitHub repos
#    (repos use git@github.com URLs — root must be able to clone them)
ssh-keygen -t ed25519 -C "vps-deploy"
cat ~/.ssh/id_ed25519.pub        # add this as a GitHub deploy key / machine user key
ssh -T git@github.com            # accept the host key once

# 5. Review & edit secrets
#    group_vars/all.yml  → mysql_users passwords, ssl_email
```

Then run the full stack:

```bash
ansible-playbook -i inventory/local.ini site.yml
```

That single command is **idempotent** — re-running it is safe and is also how you do
repeat deployments and disaster recovery.

---

## 2. Bootstrap

Installs the base system + Node + PHP toolchains only:

```bash
ansible-playbook -i inventory/local.ini playbooks/bootstrap.yml
```

Run `mysql.yml` and `redis.yml` similarly if you only want those services.

### OpenSearch (search engine)

OpenSearch (Apache-2.0, Elasticsearch 7.10-compatible API) is installed as a
single node bound to **localhost only** and reachable at:

```text
http://127.0.0.1:9200
```

It is used mainly by the **seller Express backend** (`seller_backend`, PM2 on
4001). Since that app runs on the same host, it reaches OpenSearch directly with
**no TLS and no auth**. Add to the seller backend's `.env`:

```env
# seller_backend (.env) — @opensearch-project/opensearch (or @elastic/elasticsearch v7)
OPENSEARCH_NODE=http://127.0.0.1:9200
# no username/password needed (security plugin disabled, localhost only)
```

Recommended Node client (works against OpenSearch 2.x / ES 7.10 API):

```bash
npm install @opensearch-project/opensearch
```

```js
const { Client } = require('@opensearch-project/opensearch');
const client = new Client({ node: process.env.OPENSEARCH_NODE });
```

Any other app on the box (e.g. the Laravel admin) can use the same endpoint.

Tune it in `group_vars/all.yml`:

```yaml
opensearch_version: "2"          # 2.x apt line
opensearch_http_host: "127.0.0.1"
opensearch_http_port: 9200
opensearch_heap_size: "512m"     # raise on a bigger VPS
opensearch_disable_security: true
```

> **Memory:** OpenSearch (JVM heap, default 512 MB) runs alongside MySQL, Redis
> and the CPU PyTorch/Qwen services. On a small VPS keep the heap modest, or set
> a swap file. To expose it to another host, set a bind address, re-enable
> security, and front it with TLS — do **not** open `:9200` publicly without auth.

Run just this stage with:

```bash
ansible-playbook -i inventory/local.ini playbooks/opensearch.yml
```

---

## 3. Deployment

Clone/pull all repos and (re)build them:

```bash
ansible-playbook -i inventory/local.ini playbooks/deploy.yml
```

Build behaviour per `type` (from `group_vars/production.yml`):

| type     | actions                                                            |
|----------|-------------------------------------------------------------------|
| nextjs   | `npm install` → `npm run build`                                   |
| express  | `npm install`                                                     |
| laravel  | `composer install --no-dev` → `php artisan optimize` → `migrate`  |
| python   | create venv → `pip install -r requirements.txt`                  |

### Secrets management (centralized env files)

No `.env` lives in any application repo or in git. Instead:

```text
env/<project>/.env   (in THIS repo, git-ignored)   →   /opt/secrets/<name>.env
```

The `secrets` role (run early, right after `bootstrap`) copies each env file into
`/opt/secrets` as **root:root, dir 0700 / files 0600**. Mapping is in
`group_vars/all.yml` (`secret_env_files`):

| Source (git-ignored)                 | → `/opt/secrets/`              | Consumed by              |
|--------------------------------------|--------------------------------|--------------------------|
| `env/frontend/.env`                  | `front.env`                    | PM2 `front`              |
| `env/api/.env`                       | `api.env`                      | PM2 `api`                |
| `env/admin/.env`                     | `admin.env`                    | Laravel `.env` symlink   |
| `env/seller_frontend/.env`           | `seller-front.env`             | PM2 `seller_front`       |
| `env/seller-backend/.env`            | `seller-backend.env`           | PM2 `seller_backend`     |
| `env/image-to-product-backend/.env`  | `image-to-product-backend.env` | PM2 backend + worker     |
| `env/image-to-product-python/.env`   | `image-to-product-python.env`  | python systemd services  |

How each runtime consumes them:

- **PM2 (Node):** `ecosystem.config.js` has **no secrets**. Each app launches via
  `bash -c 'set -a; . /opt/secrets/<app>.env; set +a; exec npm start'`
  (`interpreter: none`), so env vars are loaded at process start.
- **Laravel:** `/var/www/admin/.env` is a **symlink** to `/opt/secrets/admin.env`
  (created during deploy, before `artisan` runs).
- **Python systemd:** units include `EnvironmentFile=-/opt/secrets/image-to-product-python.env`.

When an env file changes, PM2 is reloaded (`--update-env`) and the affected
python services are restarted automatically (`secrets_changed` fact).

**Ansible Vault** — the only secrets Ansible itself needs (the MySQL `appuser` and
`admin` passwords) live in `group_vars/secrets.yml`. Fill them, then:

```bash
ansible-vault encrypt group_vars/secrets.yml
ansible-playbook -i inventory/local.ini site.yml --ask-vault-pass
```

(or set `vault_password_file` in `ansible.cfg`). These **must match** the
`DB_PASSWORD` in your env files. Disaster recovery recreates `/opt/secrets` and
every env file from `env/` + the vault on a fresh VPS.

> ⚠️ The `env/` folder and `*.env` are git-ignored — keep it that way. Never commit
> real secrets.

### Shared uploads folder & permissions

A central product-image uploads folder is created at `/var/www/shared/uploads`
(outside every app deployment). It is owned `www-data:www-data`, mode `2775`
(setgid), and the deploy user is in the `www-data` group — so the Laravel admin
(PHP-FPM) and the Node apps can all write to it. Each app's uploads path is a
**symlink** into it:

```yaml
shared_uploads_dir: /var/www/shared/uploads
shared_uploads_links:
  - "{{ projects.admin.path }}/public/uploads"     # Laravel admin (nginx serves public/)
  - "{{ projects.api.path }}/uploads"              # Express API
  - "{{ projects.seller_backend.path }}/uploads"   # seller Express backend
```

Every linked app reaches the **same** files under `/var/www/shared/uploads`, so an
image uploaded by the Laravel admin is immediately visible to the Express apps
and vice-versa.

**Safe migration (deploy/tasks/uploads.yml).** If an app already has a *real*
(non-empty) `uploads/` directory — e.g. shipped by the repo or created by a
previous deploy — the deploy does NOT blow it away. For each target it:
1. verifies `/var/www/shared/uploads` exists;
2. `rsync -a --update` the existing files into the shared folder (no deletes,
   never overwrites newer files), and **fails clearly** if the sync errors;
3. renames the original to `…/uploads.bak-<timestamp>` (or just removes it if it
   was empty);
4. creates the symlink.

It is fully idempotent: an already-correct symlink is left untouched, files are
never duplicated, and **no user-uploaded file is ever deleted**.

Permissions are applied automatically from `group_vars/all.yml`:

- `/var/www` and every project dir → `web_owner:web_group` (`devuser:www-data`),
  directories `2775` (setgid so new files inherit the group).
- Project ownership is re-applied **after** the build so generated files
  (`vendor/`, `node_modules/`, `.next/`) are covered.
- Laravel `storage` and `bootstrap/cache` (`laravel_writable_paths`) are made
  group-writable by `www-data`.

`/var/www` is **not** recursively `chmod`-ed (that would be slow over
`node_modules` and could break exec bits) — only ownership is recursed and key
directories get explicit modes.

### The `image_to_product` monorepo

This is **one repository**, cloned **once** to `/var/www/image-to-product`:

```text
/var/www/image-to-product
├── frontend   # Next.js  → PM2 app image_to_product_front  (port 3100)
├── backend    # Express  → PM2 app image_to_product_backend (port 4100)
└── scripts    # python   → systemd services (ports 4003 / 4004)
```

It has **no domain and no SSL**. A websocket-aware nginx reverse proxy is exposed
on the bare server IP (the `default_server` on port 80):

```text
http://SERVER_IP/         -> frontend (Next.js,  internal 3100)
http://SERVER_IP/api/     -> backend  (Express + WebSocket, internal 4100)
```

The internal ports (3100/4100) are also still reachable directly. The python AI
services (4003/4004) stay internal. Tune this in `group_vars/all.yml`:

```yaml
experimental_nginx:
  enabled: true
  listen_port: 80
  backend_location: /api    # path proxied to the express backend
```

If you use a firewall, allow port 80 (and 3100/4100 only if you want direct
access); never expose 4003/4004 publicly.

### Background processing (queues + workers)

The experimental backend uses Redis-backed queues, so a separate **worker**
process runs alongside the API. Both are managed by **PM2** (auto-restart on
crash, restored on boot via `pm2 startup`/`pm2 save`):

| PM2 app                    | Command          | Notes                         |
|----------------------------|------------------|-------------------------------|
| `image_to_product_backend` | `npm start`      | Express API + WebSocket (4100)|
| `image_to_product_worker`  | `npm run worker` | queue/pipeline worker, no port|

Adjust the worker's `args` in `group_vars/all.yml` (`pm2_apps`) to match your
`package.json` script name. The two Qwen python services run as **systemd**
units (`image-analysis-service`, `product-textinfo-generator-service`) with
`PYTHONUNBUFFERED=1` and start after Redis/MySQL.

Redis itself is configured with `supervised systemd` and verified with a
`redis-cli ping` (must return `PONG`) during the run.

### Python AI stack (Qwen models)

The deploy step builds the python environment for the Qwen services inside the
project venv (`/home/devuser/fashion-ai`). Configure it in `group_vars/all.yml`
under `ai_python`:

```yaml
ai_python:
  install_cpu_torch: true
  torch_index_url: "https://download.pytorch.org/whl/cpu"   # CPU-only PyTorch build
  pip_packages: [transformers, accelerate, flask, requests,
                 opencv-python-headless, numpy, scikit-learn, pillow, rembg]
  warmup: false                 # pre-download models (several GB) — see below
  warmup_script: load_qwen.py
```

What deploy does, in order: upgrade pip/setuptools/wheel → install **CPU PyTorch**
from the special index URL → install the AI packages → install the scripts'
`requirements.txt` if present.

**Model download:** the Qwen models (`Qwen2.5-VL-3B-Instruct`,
`Qwen2.5-1.5B-Instruct`) are several GB. By default they download lazily on the
service's first run into `~/.cache/huggingface` of the `devuser`. To pre-warm
them during provisioning instead, set `ai_python.warmup: true` and make sure a
`load_qwen.py` (or your chosen `warmup_script`) exists in the scripts dir — it
runs **as `devuser`** so the cache lands in the right home directory.

> Note: ports follow `production.yml` — VL service `4003`, text service `4004`.

---

## 4. SSL generation

```bash
ansible-playbook -i inventory/local.ini playbooks/ssl.yml
```

Uses certbot's nginx plugin to issue **one single certificate** (a SAN cert,
lineage name `colourindigo.com`) covering every production domain/subdomain:

- `colourindigo.com` / `www`
- `admin.colourindigo.com`
- `api.colourindigo.com`
- `seller.colourindigo.com`
- `seller-api.colourindigo.com`
- `phpmyadmin.colourindigo.com`

The domain list is collected from `nginx_sites`, so adding a site there
automatically includes it in the certificate. It is guarded by `creates:` so the
cert is not re-issued every run, and the `certbot.timer` handles renewal.
**The experimental project is skipped** (it has no nginx vhost).

> Because of the `creates:` guard, if you add a new subdomain later, expand the
> existing certificate once manually (then future runs stay idempotent):
>
> ```bash
> certbot --nginx --cert-name colourindigo.com --expand \
>   -d colourindigo.com -d www.colourindigo.com -d admin.colourindigo.com \
>   -d api.colourindigo.com -d seller.colourindigo.com \
>   -d seller-api.colourindigo.com -d phpmyadmin.colourindigo.com -d <new.domain>
> ```

---

## 5. PM2 management

`playbooks/pm2.yml` renders `/var/www/ecosystem.config.js` from `pm2_apps` and runs
`pm2 startOrReload`, `pm2 save`, and `pm2 startup` (boot persistence).

Managed apps: `front`, `api`, `seller_front`, `seller_backend`,
`image_to_product_front`, `image_to_product_backend`.

Useful commands on the VPS:

```bash
pm2 list
pm2 logs front
pm2 restart all
pm2 save
```

Python AI services are **systemd** units (not PM2):

```bash
systemctl status image-analysis-service
systemctl status product-textinfo-generator-service
journalctl -u image-analysis-service -f
```

---

### phpMyAdmin

phpMyAdmin is installed to `/usr/share/phpmyadmin` and served (PHP-FPM) at
`https://phpmyadmin.colourindigo.com` with cookie authentication.

Log in with the MySQL **`admin`** user. Set its password first in
[group_vars/all.yml](group_vars/all.yml):

```yaml
phpmyadmin_admin_password: "your-strong-password"   # <-- set this
```

Run just this stage with:

```bash
ansible-playbook -i inventory/local.ini playbooks/phpmyadmin.yml
```

### Seeding the database from a .sql dump

To preload the `colourindigo` database from an existing dump, copy the file onto
the VPS and point `mysql_import_file` at it in [group_vars/all.yml](group_vars/all.yml):

```bash
scp colourindigo.sql root@SERVER_IP:/root/colourindigo.sql
```

```yaml
mysql_import_db:   colourindigo
mysql_import_file: "/root/colourindigo.sql"   # "" to skip
```

The import runs (via `mysql.yml`) **only when the database has no tables**, so it
seeds a fresh database once and never overwrites live data on later runs. The
imported data is immediately visible in phpMyAdmin.

> Make sure DNS for `phpmyadmin.<domain>` points at the VPS before running `ssl.yml`.

---

## Observability (logging & monitoring)

A lightweight, self-hosted stack — **no ELK / Elasticsearch / Kibana** — chosen for
low RAM on a single VPS. Everything binds to `127.0.0.1`; only Grafana is meant to
be reverse-proxied.

```
 apps / nginx / pm2 logs ─▶ Promtail ─▶ Loki ─────────────────▶┐
 host + service exporters ─▶ Prometheus ──────────────────────▶┴─▶ Grafana
   (node / redis / mysqld / nginxlog / pm2-textfile)
```

> **Production services only.** The experimental `image_to_product` project
> (frontend, backend, and its python services) is **excluded** from all log
> collection and dashboards.

| Component         | Role             | Bind             | Purpose                              |
|-------------------|------------------|------------------|--------------------------------------|
| Loki              | `loki`           | `127.0.0.1:3310` | log storage (filesystem, 7d)         |
| Promtail          | `promtail`       | `127.0.0.1:9080` | log collection + labels              |
| Node Exporter     | `node_exporter`  | `127.0.0.1:9100` | host metrics + **systemd** + textfile|
| Redis Exporter    | `redis_exporter` | `127.0.0.1:9121` | redis metrics                        |
| MySQL Exporter    | `mysqld_exporter`| `127.0.0.1:9104` | mysql metrics                        |
| Nginx Log Exporter| `nginx_exporter` | `127.0.0.1:4040` | request/status/response-time metrics |
| PM2 metrics       | (pm2 textfile)   | via node_exporter| status/restarts/cpu/mem/uptime       |
| Prometheus        | `prometheus`     | `127.0.0.1:9090` | metrics store (scrapes all exporters)|
| Grafana           | `grafana`        | `127.0.0.1:3300` | dashboards + datasources             |

> Prometheus is included so the exporters' metrics are stored and queryable
> (a single lightweight binary, 15-day retention). Scrape targets live in
> `group_vars/all.yml` → `prometheus_jobs` (add a line + re-run `monitoring.yml`).

Playbooks: `playbooks/logging.yml` (Loki + Promtail + logrotate) and
`playbooks/monitoring.yml` (exporters + Prometheus + Grafana). Both run last in
`site.yml`. All are systemd units, enabled on boot, `Restart=on-failure`.

### Log sources & labels

Collected by Promtail (`group_vars/all.yml` → `log_sources`) — **production only**:

| Source                                       | Label                              |
|----------------------------------------------|------------------------------------|
| `/var/www/admin/storage/logs/*.log`          | `app=laravel-admin`                |
| `/var/www/api/logs/*.log`                     | `app=api`                          |
| `/var/www/seller/backend/logs/*.log`         | `app=seller-backend`               |
| `~/.pm2/logs/*.log`                           | `app=pm2`                          |
| `/var/log/nginx/*access.log` / `*error.log`  | `app=nginx`, `stream=access/error` |

### Crash detection & service health

`node_exporter` runs the **systemd collector** scoped to `monitored_systemd_units`
(nginx, mysql, redis-server, php-fpm, pm2-root, and the observability units). This
gives, for crash/restart-loop/failed-start detection:

- `node_systemd_unit_state{name="nginx.service",state="active"}` — 1 = up
- `node_systemd_service_restart_total{name=...}` — restart count
- PM2 per-process: `pm2_up`, `pm2_restarts_total`, `pm2_unstable_restarts_total`,
  `pm2_cpu_percent`, `pm2_memory_bytes`, `pm2_uptime_seconds`
  (a systemd timer runs `/usr/local/bin/pm2-metrics.sh` every 15s → node_exporter textfile).

### Alert thresholds (foundation)

No email alerts yet (as requested) — datasources + dashboards are wired so rules
drop in later (`/etc/prometheus/rules/*.yml`, then add a Grafana contact point).
The intended conditions are visualised on the dashboards:

| Condition                         | Expression (Prometheus)                                  |
|-----------------------------------|---------------------------------------------------------|
| PM2 restart loop                  | `pm2_restarts_total > 5`                                 |
| PM2 process offline               | `pm2_up == 0`                                            |
| Redis stopped                     | `redis_up == 0`                                          |
| Redis memory > 85%                | `redis_memory_used_bytes / redis_memory_max_bytes > .85`|
| Redis evictions                   | `increase(redis_evicted_keys_total[5m]) > 0`            |
| MySQL stopped                     | `mysql_up == 0`                                          |
| Nginx stopped                     | `node_systemd_unit_state{name="nginx.service",state="active"} == 0` |
| 5xx spike                         | `sum(rate(nginx_http_response_count_total{status=~"5.."}[5m])) > 0` |

### Dashboards

Auto-provisioned into the **ColourIndigo** folder (production only):

1. **Server Health** — CPU, RAM, disk, network, load, disk I/O (Prometheus)
2. **PM2 Applications** — status, restarts/crash-loops, CPU, memory, uptime, logs
3. **Redis** — up, memory %, clients, throughput, hit ratio, evictions, RDB save
4. **MySQL** — up, connections, queries/s, slow queries, uptime, buffer pool
5. **Nginx** — up, request rate, 4xx/5xx, status codes, p50/p95/p99 + upstream times, error log
6. **Application Errors** — Laravel + API + Seller-backend errors/fatals + PM2 restarts + logs

### Log retention / rotation

- **Loki** — `loki_retention_period` (default 7d), compactor enabled.
- **PM2** — `pm2-logrotate` module (`10M` max, keep 14, compress).
- **App logs** — `logrotate` (`logrotate_app_paths`, daily, keep `app_log_rotate_days`, `copytruncate`).
- **Nginx** — its own packaged logrotate. **Prometheus** — 15-day TSDB retention.

### Accessing Grafana

Bound to `127.0.0.1:3300` (not public). Reach it via an SSH tunnel:

```bash
ssh -L 3300:127.0.0.1:3300 root@SERVER_IP
# then open http://localhost:3300  (login: admin / vault_grafana_admin_password)
```

To expose it at `logs.colourindigo.com` once that DNS exists, set in
`group_vars/all.yml`:

```yaml
grafana_expose_via_nginx: true     # creates the nginx vhost (HTTP only, no SSL yet)
```

Then add `logs.colourindigo.com` to `nginx_sites` (with `ssl_domains`) to also get
a certificate on the next `ssl.yml` run.

### Loki access

Internal only (`127.0.0.1:3310`) — never exposed. Query it through Grafana, or
directly for debugging:

```bash
curl -s 'http://127.0.0.1:3310/ready'
curl -sG 'http://127.0.0.1:3310/loki/api/v1/query' --data-urlencode 'query={app="nginx"}'
```

### Adding a new log source

1. Add an entry to `log_sources` in `group_vars/all.yml`:
   ```yaml
   - { app: my-service, path: "/var/www/my-service/logs/*.log" }
   ```
2. Re-run `ansible-playbook -i inventory/local.ini playbooks/logging.yml`.
3. The new `app=my-service` label is immediately queryable in Grafana
   (`{app="my-service"}`). Add panels/dashboards as needed.

For a journald-based service, add its unit to `python_journal_units` (or create a
new journal scrape job in `roles/promtail/templates/promtail-config.yml.j2`).

### Troubleshooting

```bash
systemctl status loki promtail grafana-server prometheus node_exporter \
                 redis_exporter mysqld_exporter nginx_exporter
systemctl list-timers pm2-metrics.timer        # PM2 metrics timer firing?
journalctl -u promtail -f                      # promtail tailing/sending issues
curl -s http://127.0.0.1:3310/ready            # Loki ready?
curl -s http://127.0.0.1:9100/metrics | grep pm2_   # PM2 + host metrics present?
curl -s http://127.0.0.1:9121/metrics | head   # Redis exporter
curl -s http://127.0.0.1:9104/metrics | head   # MySQL exporter
curl -s http://127.0.0.1:4040/metrics | head   # Nginx log exporter
curl -s http://127.0.0.1:9090/-/healthy        # Prometheus healthy?
# Targets all UP?  tunnel to Grafana/Prometheus and open /targets
```

- **No logs in Grafana:** check Promtail can read the files
  (`journalctl -u promtail`), that the path glob matches, and that the app is
  actually writing logs there.
- **Empty VPS Health dashboard:** confirm Prometheus is scraping Node Exporter —
  `http://127.0.0.1:9090/targets` (via tunnel) should show the `node` job UP.
- **Grafana login fails:** the password is `vault_grafana_admin_password`; if you
  changed it after first boot, Grafana keeps the old one in its DB — reset with
  `grafana-cli admin reset-admin-password <new>`.

---

## Alerting, crash detection & error reporting

Built on the **existing** Prometheus + Grafana (Loki/Promtail untouched). See
[docs/observability-onboarding.md](docs/observability-onboarding.md) for adding
services, domains, alert rules, and GlitchTip SDK setup.

| Capability         | Component                         | Bind / where                         |
|--------------------|-----------------------------------|--------------------------------------|
| Crash detection    | `process_exporter` + node systemd | `127.0.0.1:9256`                     |
| Uptime probes      | `blackbox_exporter`               | `127.0.0.1:9115`                     |
| Alert rules + email| `alerting` (Grafana provisioning) | `/etc/grafana/provisioning/alerting` |
| Error reporting    | `glitchtip` (Docker)              | `127.0.0.1:8080`                     |

### Crash / service detection
`process_exporter` tracks `process_groups` (nginx, php-fpm, redis, mysqld, node,
pm2, laravel-queue, laravel-schedule, docker). `process_required` fires a
critical alert when a required process hits 0 instances. node_exporter's systemd
collector adds up/down + restart-loop detection; PM2 metrics add offline +
restart-loop.

### Uptime monitoring
`blackbox_exporter` probes every URL in `blackbox_targets` (main site, admin, API,
seller, seller-api; add health endpoints). Alerts: not-200 / unreachable
(`probe_success`), slow (`probe_duration_seconds > alert_response_time_seconds`),
TLS expiry (`< alert_cert_expiry_days`).

### Grafana alerting (auto-provisioned, no manual setup)
Alert groups: **Infrastructure, Services, Websites, APIs, Databases, Redis,
Application Errors**. All thresholds are variables (`alert_*` in `all.yml`).
Notifications go by **email to `throwmegigs@gmail.com`** (Grafana SMTP via
`alert_smtp_*` + `vault_alert_smtp_password`); severities `critical/warning/info`;
payload includes environment, host, service/app, reason, status, timestamp.

### GlitchTip (application errors)
Self-hosted Sentry-compatible error tracking (Docker: web + worker + postgres +
redis), reachable at `http://SERVER_IP:8080`. Create a project per app, copy the
DSN into that app's `env/<project>/.env`, re-run `secrets.yml`. SDK snippets for
Laravel / Next.js / Express are in the onboarding doc. Disable entirely with
`glitchtip_enabled: false`.

> **Resource note:** GlitchTip adds its own Postgres + Redis + Python containers.
> On a small VPS that's significant RAM on top of MySQL/OpenSearch/Prometheus —
> size accordingly or set `glitchtip_enabled: false`.

Run just these stages:

```bash
ansible-playbook -i inventory/local.ini playbooks/monitoring.yml --ask-vault-pass  # exporters + alerts
ansible-playbook -i inventory/local.ini playbooks/glitchtip.yml  --ask-vault-pass  # error reporting
```

---

## 6. Disaster recovery (rebuild a VPS from scratch)

1. Provision a new Ubuntu 24.04 VPS.
2. Follow **First VPS setup** (install Ansible, clone repo, install collections,
   add the SSH deploy key).
3. (Optional) restore data from a backup produced by `playbooks/backup.yml`
   (`/var/backups/infra/*.sql`, `www-*.tar.gz`).
4. Run:

   ```bash
   ansible-playbook -i inventory/local.ini site.yml
   ```

Everything — packages, databases, code, PM2, systemd, nginx, SSL — is recreated
idempotently. Create a backup at any time with:

```bash
ansible-playbook -i inventory/local.ini playbooks/backup.yml
```

---

## 7. Adding a new project

1. Add it to **`group_vars/production.yml`** under `projects:`

   ```yaml
   projects:
     myapp:
       repo: git@github.com:org/myapp.git
       path: /var/www/myapp
       type: nextjs        # nextjs | express | laravel | python
       port: 3002
   ```

2. If it is a **Node** app that PM2 should run, add it to `pm2_apps` in
   `group_vars/all.yml`.
3. If it needs a **domain**, add an entry to `nginx_sites` in `group_vars/all.yml`
   (set `type: proxy` + `port`, or `type: php` + `root`, plus `ssl_domains`).
4. Re-run the stack:

   ```bash
   ansible-playbook -i inventory/local.ini site.yml
   ```

No template or role edits are required — everything is generated from variables.

---

## 8. Running the full stack

```bash
ansible-playbook -i inventory/local.ini site.yml
```

Run order: **bootstrap → mysql → redis → deploy → pm2 → nginx → ssl**.

### Handy flags

```bash
# dry run
ansible-playbook -i inventory/local.ini site.yml --check

# run a single stage by tag-free playbook
ansible-playbook -i inventory/local.ini playbooks/nginx.yml

# syntax check
ansible-playbook -i inventory/local.ini site.yml --syntax-check
```

---

## Notes & prerequisites

- **Collections:** run `ansible-galaxy collection install -r requirements.yml` first
  (MySQL DB/user creation uses `community.mysql`).
- **Secrets:** edit passwords in `group_vars/all.yml`. For production, move them into
  an Ansible Vault file.
- **Git access:** root's SSH key must be able to clone the private GitHub repos.
- **MySQL auth:** on Ubuntu 24.04 the root account uses `auth_socket`; the playbooks
  connect over the local unix socket, so they must run as root (they do, via `become`).
