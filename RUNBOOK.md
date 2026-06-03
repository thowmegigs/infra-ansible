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

### 4a. How env files work (no plaintext `env/` folder)

Each project's `.env` is **rendered** during the `secrets` stage into
`/opt/secrets/<project>.env` (root-only `0600`, outside the project folder) from:

- **`vars/env.yml`** — non-secret values (ports, hosts, URLs, public keys).
  Committed to git.
- **`group_vars/secrets.yml`** — the secret values (vault). **Not committed**
  unless encrypted.

Node apps source their file via PM2; Laravel gets a symlink
`/var/www/admin/.env → /opt/secrets/admin.env`.

> ⚠️ `group_vars/secrets.yml` is git-ignored (it holds real credentials). Get it
> onto the VPS one of two ways:
>
> **Option A — scp it (simplest):**
> ```bash
> scp group_vars/secrets.yml root@SERVER_IP:/root/infra-ansible/group_vars/
> ```
> **Option B — encrypt and commit it (travels with git):**
> ```bash
> ansible-vault encrypt group_vars/secrets.yml
> git add -f group_vars/secrets.yml && git commit -m "vault secrets" && git push
> ```
> Either way, run with `--ask-vault-pass` once it's encrypted.

To change a value: edit `vars/env.yml` (non-secret) or `secrets.yml` (secret), then
re-run `playbooks/secrets.yml` (+ `pm2.yml` for Node apps to pick it up).

### 4b. Make DB credentials line up

All apps connect to MySQL as user **`admin`** with `vault_db_password`. Ansible
creates that account from `vault_phpmyadmin_password`, so keep both equal:
```yaml
vault_db_password:         "MangoTree@20252024"
vault_phpmyadmin_password: "MangoTree@20252024"
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
