# RUNBOOK — provisioning & deploying the VPS

Step-by-step operational guide. Ansible runs **locally on the VPS** (no SSH from a
control machine). For architecture/role details see [README.md](README.md).

Final command is always:

```bash
ansible-playbook -i inventory/local.ini site.yml
```

---

## 1. Get the repo onto the VPS

```bash
# Option A — clone (if infra-ansible is pushed to GitHub)
ssh root@SERVER_IP
git clone <your-infra-ansible-repo-url> infra-ansible
cd infra-ansible
```

```powershell
# Option B — copy from your Windows machine
scp -r d:\ansible root@SERVER_IP:/root/infra-ansible
```

---

## 2. Install Ansible + collections (on the VPS)

```bash
sudo apt update && sudo apt install -y ansible git
cd ~/infra-ansible
ansible-galaxy collection install -r requirements.yml   # community.mysql, community.general, ansible.posix
```

---

## 3. Give the VPS access to the private GitHub repos

`group_vars/production.yml` uses `git@github.com:…` URLs, so root needs an SSH key
GitHub trusts:

```bash
ssh-keygen -t ed25519 -C "vps-deploy"     # press enter through the prompts
cat ~/.ssh/id_ed25519.pub                  # add to GitHub as a deploy key / machine-user key
ssh -T git@github.com                      # accept the host key once
```

---

## 4. Secrets & values

### 4a. App env files (`env/<project>/.env`)

Real `.env` files live in `env/` **in this repo** (git-ignored) and are copied to
`/opt/secrets/*.env` by the `secrets` play. Files: `frontend, api, admin,
seller_frontend, seller-backend, image-to-product-backend, image-to-product-python`.

> ⚠️ **`env/` is git-ignored, so `git clone` on the VPS does NOT include it.**
> You MUST copy it onto the VPS once (and after any change):
>
> ```bash
> scp -r ./env  root@SERVER_IP:/root/infra-ansible/env
> ```
>
> If it's missing, the `secrets` play now fails fast with this instruction
> (instead of letting Laravel/Node break later with a dangling `.env`).

Make sure ports/URLs match the deployment (README → *Secrets management*), and that
the DB user/password in each `.env` matches what MySQL creates:
`appuser`/`vault_app_db_password` (or, if an app's `.env` uses `admin`, set
`vault_phpmyadmin_password` to that same password).

### 4b. Vault (passwords Ansible needs)

`group_vars/secrets.yml` holds the MySQL `appuser` + phpMyAdmin `admin` passwords.
They **must match** `DB_PASSWORD` in your env files. Encrypt it:

```bash
ansible-vault encrypt group_vars/secrets.yml
# then run with --ask-vault-pass  (or set vault_password_file in ansible.cfg)
```

### 4c. Other values in `group_vars/all.yml`

| Variable            | What to set                                                        |
|---------------------|--------------------------------------------------------------------|
| `node_version`      | **verify it exists** (below); else set `""` or a real 20.x         |
| `mysql_import_file` | path to the SQL dump on the VPS                                    |
| `ssl_email`         | defaults to `admin@<domain>` — change if needed                    |

Verify the pinned Node version is available before running:

```bash
apt-cache madison nodejs        # if 20.20.1 is missing, set node_version: "" (latest 20.x)
```

---

## 5. Put the SQL dump on the VPS

```powershell
scp d:\path\to\colourindigo.sql root@SERVER_IP:/root/colourindigo.sql
```

Imported automatically by `mysql.yml`, but **only if the `colourindigo` database is
empty** (so it never overwrites live data).

---

## 6. Point DNS at the VPS (required for SSL)

Create `A` records → server IP for every production name:

```
colourindigo.com
www.colourindigo.com
admin.colourindigo.com
api.colourindigo.com
seller.colourindigo.com
seller-api.colourindigo.com
phpmyadmin.colourindigo.com
```

Certbot issues **one** combined certificate; it fails for any name that does not
resolve to this server. The experimental project uses the bare IP (no DNS/SSL).

---

## 7. (Optional) Clean an existing stack first

If projects are already running on this VPS from a manual setup:

```bash
chmod +x scripts/reset-vps.sh
sudo ./scripts/reset-vps.sh          # backs up DB + /var/www first, then a LIGHT reset
# sudo ./scripts/reset-vps.sh --full # also apt-purges nginx/mysql/php/node/redis/certbot
```

A timestamped backup is written to `/root/pre-reset-backup-*` before anything is
removed. The script preserves `/var/www/uploads`.

---

## 8. Run

```bash
# Dry run (shows intended changes; some dependent tasks may error in check mode)
ansible-playbook -i inventory/local.ini site.yml --check

# Real run
ansible-playbook -i inventory/local.ini site.yml

# More detail
ansible-playbook -i inventory/local.ini site.yml -v
```

Run order: **bootstrap → secrets → mysql → redis → opensearch → phpmyadmin → deploy → pm2 → nginx → ssl → logging → monitoring → glitchtip**.

> If `group_vars/secrets.yml` is encrypted, add `--ask-vault-pass` to every run.

---

## Run a single stage

```bash
ansible-playbook -i inventory/local.ini playbooks/bootstrap.yml    # base pkgs + Node + PHP
ansible-playbook -i inventory/local.ini playbooks/secrets.yml      # copy env/ -> /opt/secrets
ansible-playbook -i inventory/local.ini playbooks/mysql.yml        # DB/users + dump import
ansible-playbook -i inventory/local.ini playbooks/redis.yml        # Redis
ansible-playbook -i inventory/local.ini playbooks/opensearch.yml   # OpenSearch (localhost :9200)
ansible-playbook -i inventory/local.ini playbooks/phpmyadmin.yml   # phpMyAdmin
ansible-playbook -i inventory/local.ini playbooks/deploy.yml       # clone/build + uploads + AI deps
ansible-playbook -i inventory/local.ini playbooks/pm2.yml          # Node apps + worker
ansible-playbook -i inventory/local.ini playbooks/nginx.yml        # vhosts
ansible-playbook -i inventory/local.ini playbooks/ssl.yml          # certbot (after DNS is live)
ansible-playbook -i inventory/local.ini playbooks/logging.yml      # Loki + Promtail + logrotate
ansible-playbook -i inventory/local.ini playbooks/monitoring.yml   # exporters + Prometheus + Grafana + alerts
ansible-playbook -i inventory/local.ini playbooks/glitchtip.yml    # GlitchTip error reporting (Docker)
```

---

## Post-run checks

```bash
pm2 list                                           # node apps + worker online
systemctl status image-analysis-service            # Qwen VL  (port 4003)
systemctl status product-textinfo-generator-service # Qwen text (port 4004)
redis-cli ping                                     # -> PONG
curl -s http://127.0.0.1:9200 | head              # OpenSearch responds (no auth, localhost)
systemctl status nginx php8.2-fpm mysql redis-server opensearch
systemctl status loki promtail grafana-server prometheus node_exporter \
                 redis_exporter mysqld_exporter nginx_exporter \
                 process_exporter blackbox_exporter
systemctl list-timers pm2-metrics.timer           # PM2 metrics exporter firing
curl -s http://127.0.0.1:3310/ready               # Loki ready
curl -s http://127.0.0.1:9115/metrics | head      # Blackbox exporter
curl -s http://127.0.0.1:9256/metrics | grep namedprocess | head   # Process exporter
docker compose -f /opt/glitchtip/docker-compose.yml ps             # GlitchTip containers
ssh -L 3300:127.0.0.1:3300 root@SERVER_IP         # tunnel → http://localhost:3300 (Grafana)
# In Grafana: dashboards + Alerting → rule groups (ColourIndigo Alerts); Prometheus /targets UP
# GlitchTip: ssh -L 8080:127.0.0.1:8080 → http://localhost:8080 → create projects → DSNs
nginx -t                                           # config OK
ls -ld /var/www/uploads                            # www-data:www-data, drwxrwsr-x
```

Then browse:

- `https://colourindigo.com`, `https://admin.colourindigo.com`, `https://api.colourindigo.com`
- `https://seller.colourindigo.com`, `https://seller-api.colourindigo.com`
- `https://phpmyadmin.colourindigo.com` (log in as `admin`)
- `http://SERVER_IP/` and `http://SERVER_IP/api/` (experimental, IP-only)

---

## Common first-run gotchas

| Symptom | Cause / fix |
|---------|-------------|
| `bootstrap` fails on nodejs | Pinned `node_version` not in NodeSource — set `""` or a real 20.x (`apt-cache madison nodejs`) |
| `--check` reports errors | Expected for dependent tasks in dry-run; trust the real run |
| Laravel `migrate`/`optimize` fails | Admin repo needs a valid `.env` pointing at the `colourindigo` DB |
| certbot fails for a domain | That subdomain's DNS isn't pointing here yet — fix DNS, re-run `ssl.yml` |
| git clone permission denied | SSH deploy key not added to GitHub / host key not accepted (step 3) |
| uploads symlink task fails | A repo ships a real `uploads/` dir in git — remove/migrate it (force won't clobber a non-empty dir) |

---

## Repeat deployments & disaster recovery

Just re-run the same command — it is idempotent:

```bash
ansible-playbook -i inventory/local.ini site.yml
```

Take a backup any time:

```bash
ansible-playbook -i inventory/local.ini playbooks/backup.yml   # -> /var/backups/infra
```
