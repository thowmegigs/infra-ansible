# Observability onboarding

How to add services, domains, alerts, and error reporting to the existing stack.
Everything is variable-driven in `group_vars/all.yml` (+ secrets in
`group_vars/secrets.yml`). Re-run the relevant playbook after any change.

> This extends the existing monitoring (Prometheus + Grafana + exporters) and
> logging (Loki + Promtail). It never modifies the logging stack.

---

## 1. Add an uptime probe (website / API / health endpoint)

`group_vars/all.yml` → `blackbox_targets`:

```yaml
blackbox_targets:
  - { name: main-website, url: "https://colourindigo.com" }
  - { name: api-health,   url: "https://api.colourindigo.com/health" }   # add this
```

```bash
ansible-playbook -i inventory/local.ini playbooks/monitoring.yml --ask-vault-pass
```

The `Websites` alert group automatically covers every probe: down (`probe_success`),
slow (`probe_duration_seconds`), and TLS expiry. No per-URL rule needed.

---

## 2. Monitor a new process / service (crash detection)

`group_vars/all.yml` → `process_groups` (define how to match it) and, if it must
always run, `process_required` (alert when it disappears):

```yaml
process_groups:
  - { name: my-worker, cmdline: ["my-worker.js"] }

process_required:
  - my-worker
```

Re-run `monitoring.yml`. The `Services` group alerts on `num_procs == 0`.

System services (with a systemd unit) can instead be added to
`monitored_systemd_units` — node_exporter then exports up/down + restart counts.

---

## 3. Tune alert thresholds

All thresholds are variables in `group_vars/all.yml`:

```yaml
alert_cpu_high: 90
alert_mem_high: 90
alert_disk_used_high: 85
alert_inode_used_high: 85
alert_load_high: 4
alert_swap_used_high: 80
alert_response_time_seconds: 2
alert_cert_expiry_days: 14
alert_pm2_restarts: 5
alert_redis_mem_high: 85
alert_app_error_rate: 10
```

Add a brand-new rule by appending to `grafana_alert_rules` in
`roles/alerting/defaults/main.yml` (each entry: group/uid/title/severity/
datasource/expr/op/threshold/for/summary), then re-run `monitoring.yml`.

---

## 4. Email alerting

Configured for **throwmegigs@gmail.com**. SMTP settings live in `all.yml`
(`alert_smtp_*`) and the password in the vault (`vault_alert_smtp_password`).

```yaml
alerting_email_enabled: true
alert_email_to: "throwmegigs@gmail.com"
alert_smtp_host: "smtp.zoho.in"
alert_smtp_port: 587
alert_smtp_user: "support@colourindigo.com"
```

Grafana sends from these via SMTP; the email payload includes environment, host,
severity, service/app, status, reason, and timestamp. Severity is a rule label
(`critical` / `warning` / `info`). To add Slack/Telegram later, add another
contact point file under `roles/alerting/templates/` — no redesign needed.

---

## 5. GlitchTip — application error reporting

Self-hosted (Docker) at `http://SERVER_IP:8080` (or `https://glitchtip.<domain>`
once you set `glitchtip_expose_via_nginx: true` and DNS resolves).

### First-time setup
1. Deploy: `ansible-playbook -i inventory/local.ini playbooks/glitchtip.yml --ask-vault-pass`
2. Open the URL, register the first user (becomes admin — open registration is
   then disabled by `ENABLE_OPEN_USER_REGISTRATION=False`).
3. Create an Organization → Project per app (Laravel / Next.js / Express).
4. Copy each project's **DSN** and put it in that app's env file under
   `env/<project>/.env` (then re-run `playbooks/secrets.yml`).

### Laravel (`env/admin/.env`)

```env
SENTRY_LARAVEL_DSN=https://<key>@glitchtip.colourindigo.com/<project-id>
SENTRY_TRACES_SAMPLE_RATE=0.2
```
```bash
composer require sentry/sentry-laravel
php artisan sentry:publish --dsn=$SENTRY_LARAVEL_DSN
```
Captures exceptions, fatal errors, unhandled exceptions automatically. For queue
/ failed jobs, Sentry's Laravel integration reports failed jobs out of the box;
ensure the queue worker has the same `.env`.

### Next.js (`env/frontend/.env`, `env/seller_frontend/.env`)

```env
NEXT_PUBLIC_SENTRY_DSN=https://<key>@glitchtip.colourindigo.com/<project-id>
SENTRY_ENVIRONMENT=production
```
```bash
npm install @sentry/nextjs
```
`sentry.client.config.ts` / `sentry.server.config.ts`:
```ts
import * as Sentry from "@sentry/nextjs";
Sentry.init({
  dsn: process.env.NEXT_PUBLIC_SENTRY_DSN,
  environment: process.env.SENTRY_ENVIRONMENT,
  tracesSampleRate: 0.2,
});
```
Captures frontend runtime errors, React errors, API-route failures.

### Express (`env/api/.env`, `env/seller-backend/.env`)

```env
SENTRY_DSN=https://<key>@glitchtip.colourindigo.com/<project-id>
SENTRY_ENVIRONMENT=production
```
```bash
npm install @sentry/node
```
```js
const Sentry = require("@sentry/node");
Sentry.init({ dsn: process.env.SENTRY_DSN, environment: process.env.SENTRY_ENVIRONMENT });

// after routes:
app.use(Sentry.Handlers.errorHandler());
// crash safety:
process.on("unhandledRejection", (e) => Sentry.captureException(e));
process.on("uncaughtException", (e) => { Sentry.captureException(e); process.exit(1); });
```
Captures unhandled exceptions, unhandled promise rejections, API failures.

> GlitchTip is Sentry-API compatible, so the official `@sentry/*` SDKs work
> unchanged — only the DSN host points at your GlitchTip instance.

---

## 6. Add a new domain end-to-end

1. `projects` / `nginx_sites` (serve it) → `nginx.yml`, `ssl.yml`
2. `blackbox_targets` (uptime) → `monitoring.yml`
3. `log_sources` (logs) → `logging.yml`
4. Create a GlitchTip project + DSN → app `.env` → `secrets.yml`

Each step is independent and idempotent.
