# production-service-env
A production-style microservices environment with Nginx reverse proxy, systemd lifecycle management, structured logging, and request tracing.

## Running with Docker Compose

Everything below this section documents the original VM/systemd deployment. There's also a fully containerized version on the `feature/docker-compose` branch (`docker-compose.yml`, `services/*/Dockerfile`, `nginx/docker-compose.conf`) that preserves the same properties - Nginx as the only public entry point, matching-service/dispatch-service internal-only, the same ride-api → matching-service → dispatch-service → ride-api flow, structured logs, and request tracing - just running under Docker instead of systemd on a VM. See `docs/CONTAINER_VALIDATION.md` for full command-by-command proof it works.

**Start the system**
```
docker compose up --build -d
```
matching-service and dispatch-service must report `healthy` before ride-api starts, and ride-api must report `healthy` before Nginx starts - enforced by `depends_on: condition: service_healthy` in `docker-compose.yml`. This is the Compose equivalent of the VM version's systemd `ExecStartPre` readiness gate.

**Test the public route**
```
curl -i http://localhost:8080/ride-api/health
curl -i http://localhost:8080/ride-api/request-ride
```

**Prove matching-service and dispatch-service are internal-only**
```
curl -i --connect-timeout 3 http://localhost:3002/health   # connection refused - no host port published
curl -i --connect-timeout 3 http://localhost:3003/health   # connection refused - no host port published
docker compose ps                                            # matching-service/dispatch-service show "3002/tcp"/"3003/tcp", no host mapping
```

**View logs**
```
docker compose logs                  # everything
docker compose logs -f ride-api     # follow one service
docker compose logs | grep <request-id>   # trace one request across Nginx + all three services
```

**Stop / restart a service**
```
docker compose stop matching-service        # ride-api stays up, returns a graceful 502 for that one path
docker compose start matching-service       # recovers immediately, no other steps needed
docker compose restart ride-api
```

**Shut everything down**
```
docker compose down                  # stop and remove containers + network
docker compose down -v                # also remove the (unused, stateless) volumes
```

## Observability — Metrics & Alerting

Each service exposes Prometheus metrics; a `prometheus` container scrapes them and evaluates alert rules. (Grafana and Jaeger are added in the observability lab’s other pillars.)

**What each service exposes** at `/metrics`:

| Metric | Type | Labels | Answers |
|--------|------|--------|---------|
| `http_requests_total` | counter | service, method, route, status_code | traffic / how many requests |
| `http_request_duration_seconds` | histogram | service, method, route | latency (p95 via `histogram_quantile`) |
| `http_errors_total` | counter | service, method, route, status_code | how many 5xx |
| `service_up` | gauge | service | is the process running |

**View metrics**
```
docker compose up -d --build
curl -s http://localhost:8080/ride-api/health          # generate some traffic
docker compose exec ride-api curl -s http://localhost:3001/metrics   # raw metrics
# Prometheus UI (targets should all be UP):  http://localhost:9090/targets
# Example queries in Prometheus:
#   sum by (service) (rate(http_requests_total[1m]))                              # request rate
#   sum by (service) (rate(http_errors_total[2m]))                               # error rate
#   histogram_quantile(0.95, sum by (service, le) (rate(http_request_duration_seconds_bucket[5m])))  # p95
```

**Alerts** (`alert-rules.yml`, loaded by Prometheus — see `http://localhost:9090/alerts`):

| Alert | Fires when | Reproduce |
|-------|-----------|-----------|
| `ServiceDown` | `up{job=~"ride-api\|matching-service\|dispatch-service"} == 0` for 30s | `docker compose stop matching-service` |
| `HighErrorRate` | 5xx rate > 0.1/s (per service) for 1m | drive a failure endpoint / stop a downstream under load |
| `HighLatency` | p95 > 0.5s (per service) for 2m | run the stress load test / `/slow` endpoint |

Each rule documents its meaning, likely causes, reproduction, first checks, and how to confirm normal state in the annotations of `alert-rules.yml`. Confirm an alert by triggering it (e.g. `docker compose stop matching-service`), then watching it move `Pending → Firing` at `http://localhost:9090/alerts`, and clear again after `docker compose start matching-service`.


## Container CI/CD Deployment

GitHub Actions (`.github/workflows/container-ci-cd.yml`) automates verification, packaging, and publishing for the containerized stack:

- **`verify`** (every PR + push to `main`): installs each service's Python dependencies, runs its `pytest` suite (`services/service-*/tests/`), and builds its Docker image locally. Never pushes images.
- **`verify-compose`** (needs `verify`): validates `docker compose config`, builds the full stack, brings it up, curls the gateway health route (`http://localhost:8080/ride-api/health`), and tears the stack down.
- **`publish`** (needs `verify-compose`, only on push to `main`): logs into Docker Hub and pushes each service image tagged `sha-<short-commit-hash>` (never `latest`), with OCI labels for revision and source repo.

Required repository configuration:
- Variable `DOCKERHUB_USERNAME`
- Secret `DOCKERHUB_TOKEN`

### Latest deployed version

Commit:
`67f4d40cbbefcbe2810676df3dff3cbcc7b53c6e`

Image tag:
`sha-67f4d40`

Images:
- `meronkahsay/production-service-env-ride-api:sha-67f4d40`
- `meronkahsay/production-service-env-matching-service:sha-67f4d40`
- `meronkahsay/production-service-env-dispatch-service:sha-67f4d40`

### Deploy

```bash
cp .env.example .env
export DOCKERHUB_USERNAME=<dockerhub-username>
export APP_NAME=production-service-env
./scripts/deploy.sh sha-<short-commit-hash>
```

### Verify

```bash
docker compose -f docker-compose.prod.yml ps
curl http://localhost:8080/ride-api/health
```

`docker-compose.prod.yml` pulls pre-built images from Docker Hub (`image:`) instead of building locally (`build:`) — the same network isolation as the dev stack applies: only Nginx publishes a host port (`8080`), and the `backend` network is `internal: true` so `matching-service`/`dispatch-service` are unreachable from the host even by container name.

## Observability (Metrics, Logs, Traces, Alerts)

`docker-compose.yml` now includes a MELT observability layer alongside the three services: **Prometheus** (metrics), **Jaeger** (distributed tracing), and **Grafana** (central operating view). See [docs/architecture.md](docs/architecture.md) for the full telemetry-flow diagram.

**Start the stack** (same command as before — observability containers come up alongside the app):
```
docker compose up --build -d
```

**Access each tool:**

| Tool | URL | Purpose |
|------|-----|---------|
| Grafana | http://localhost:3000 | Central dashboard — service health, request rate, error rate, p95 latency, alert state. Anonymous viewer access enabled; admin login is `admin`/`${GRAFANA_ADMIN_PASSWORD:-admin}` (set in `.env`, see `.env.example`). |
| Prometheus | http://localhost:9090 | Raw metrics + alert rule evaluation. Check **Status → Targets** to confirm all three services show `UP`. |
| Jaeger | http://localhost:16686 | Distributed traces. Search by service name to see the full request path across ride-api → matching-service → dispatch-service. |

**Run the load test** (see [docs/benchmark-report.md](docs/benchmark-report.md) for recorded results):
```
k6 run scripts/load-test.js                    # all three scenarios back-to-back
k6 run -e SCENARIO=normal  scripts/load-test.js
k6 run -e SCENARIO=stress  scripts/load-test.js
k6 run -e SCENARIO=failure scripts/load-test.js
```

**Trigger a controlled failure** (for demoing alerts/traces/logs together):
```
docker compose stop matching-service        # Failure 1: service down
curl http://localhost:8080/ride-api/slow    # Failure 2: high latency
curl http://localhost:8080/ride-api/fail    # Failure 3: high error rate
```

**View metrics / traces / logs:**
```
curl http://localhost:8080/ride-api/metrics   # raw Prometheus text output
docker compose logs -f ride-api               # structured JSON logs, same as base lab
# Traces: open http://localhost:16686, search by service name
```

**Confirm an alert fired:**
1. Trigger the matching failure (above).
2. Open Prometheus → **Alerts** (http://localhost:9090/alerts) — the rule should move from `pending` to `firing`.
3. Or check the "Alert State" panel on the Grafana dashboard.

## Overview

Three independent Python/Flask HTTP services sit behind an Nginx reverse proxy. Only **ride-api** is public (through Nginx on port 80); **matching-service** and **dispatch-service** are internal-only. A single request flows through all of them and is traceable end to end by a shared `X-Request-ID`:

```
Client → Nginx (:80) → ride-api (:3001) → matching-service (:3002) → dispatch-service (:3003) → ride-api callback
```

| Component | Port | Public? | Role |
|-----------|------|---------|------|
| Nginx | 80 | yes | Reverse proxy; the only public entry point |
| ride-api | 3001 | via Nginx only | Entry point; calls matching-service; receives dispatch-service's callback |
| matching-service | 3002 | internal | Receives from ride-api; forwards to dispatch-service |
| dispatch-service | 3003 | internal | Processes; calls back to ride-api |

## Prerequisites

These are **Linux + systemd** services, so they run on an Ubuntu host or VM (not natively on macOS/Windows). You need:
- Ubuntu 22.04+ (or similar systemd-based Linux)
- `python3` + `python3-venv`, `nginx`, `curl`, `git`
- `sudo`/root access (for `/opt`, systemd units, `/etc/hosts`, and Nginx)

**Running locally on macOS/Windows?** Use a small Ubuntu VM. With [Multipass](https://multipass.run):
```
multipass launch --name service-env 22.04
multipass shell service-env        # everything below runs inside the VM
multipass info service-env         # note the IPv4 — used for the network-security test
```

## Quick Start (run it locally, top to bottom)

Run these inside the Ubuntu host/VM. Each block is detailed in its own section further down.

### Option A — one command (recommended)

After cloning, a single idempotent installer does the entire deploy (dependencies, `/opt` layout, `serviceenv` user, venv, `/etc/hosts`, firewall, systemd units, Nginx) and finishes with the smoke test:

```
sudo apt update && sudo apt install -y git
git clone https://github.com/nebyathhailu/production-service-env.git
cd production-service-env
sudo ./scripts/install.sh        # or:  make install
```

If it ends with `Results: 5 passed, 0 failed`, you're done. The manual steps below (Option B) are the same actions broken out, for when you want to understand or run a single piece.

### Option B — manual, step by step

#### 1. Get the code
```
sudo apt update && sudo apt install -y python3-venv nginx curl git
git clone https://github.com/nebyathhailu/production-service-env.git
cd production-service-env
```
#### 1b. Pre-flight: make sure ports 3001/3002/3003 are free. If a previous run
```
#     left a manual `python app.py` behind, systemd can't bind and you'll see
#     "Matching service unreachable". Empty output here = good, you're clear to deploy.
sudo ss -ltnp '( sport = :3001 or sport = :3002 or sport = :3003 )'
pkill -f 'services/\(ride-api\|matching-service\|dispatch-service\)/app.py' || true     # clear any stray manual runs
```
#### 2. Deploy the services (creates /opt/service-env, venv, serviceenv user, systemd units)
```
sudo mkdir -p /opt/service-env
sudo cp -r services requirements.txt /opt/service-env/
sudo useradd --system --no-create-home --shell /usr/sbin/nologin serviceenv || true
sudo python3 -m venv /opt/service-env/venv
sudo /opt/service-env/venv/bin/pip install -r /opt/service-env/requirements.txt
sudo chown -R serviceenv:serviceenv /opt/service-env
sudo ./scripts/hosts-setup.sh                       # service discovery (/etc/hosts) — must run first
sudo cp systemd/service-*.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now matching-service dispatch-service ride-api
sudo ss -ltnp '( sport = :3001 or sport = :3002 or sport = :3003 )'   # confirm all 3 are listening
```
#### 2b. Firewall — defense-in-depth backstop (only 22 + 80 inbound)
```
sudo ./scripts/firewall-setup.sh
```
#### 3. Deploy Nginx
```
sudo rm -f /etc/nginx/sites-enabled/default /etc/nginx/conf.d/default.conf
sudo cp nginx/service-env.conf /etc/nginx/conf.d/service-env.conf
sudo nginx -t && sudo systemctl reload nginx
```
#### 4. Smoke test — health, the full chain, and that matching-service/dispatch-service aren't routable
```
curl -s http://localhost/ride-api/health ; echo
curl -s http://localhost/ride-api/request-ride ; echo
curl -s -o /dev/null -w '%{http_code}\n' http://localhost/matching-service
```
**Expected output:**
```
{"message":"Hello ride-api listening on 3001","port":3001,"service":"ride-api","status":"healthy"}
{"message":"Request completed successfully","request_id":"...","status":"success"}
404
```

If all three services are `active` and the chain returns `"status":"success"`, **the system is fully deployed — you only run the Quick Start once.**

### What to read next (and what each part tests)

Everything below is **explanation and tests, not setup to repeat.** The "Install / first deploy" and Nginx "Deploy" blocks in those sections are the *same commands you just ran*, broken out with explanation — you don't need to run them again. Use the table to jump to whatever you want to verify:

| What you want to check | Go to section | What that test proves |
|------------------------|---------------|-----------------------|
| Services restart on crash, recover after reboot, and order ride-api-after-matching-service/dispatch-service correctly | **Services & systemd Lifecycle → Verify lifecycle** | systemd lifecycle + dependency management |
| One request is traceable across every service by its `request_id` | **Logs** | request tracing / structured logging |
| Only ride-api is reachable through Nginx; matching-service and dispatch-service are **not** | **Nginx → Verify** | reverse proxy + network security |
| Everything at once, pass/fail in one command | **Evidence / Proof Pack** (`make verify` / `./scripts/test-end-to-end.sh`) | full end-to-end |

## Services & systemd Lifecycle (`systemd/*.service`)

The three Python/Flask services run as systemd units so they start on boot, restart on failure, log to journald, and honour the ride-api→depends-on→matching-service,dispatch-service ordering.

**Deployment layout**
- Code: `/opt/service-env/services/service-{a,b,c}/`
- Shared virtualenv: `/opt/service-env/venv/`
- Runs as the unprivileged system user `serviceenv` (no login, no home) — keeps services off `root` and lets the unit hardening (`ProtectHome`, `ProtectSystem`) apply.

**Dependency management** (assignment requirement: ride-api must not start before matching-service and dispatch-service, and must not become operational until they are available)
- `ride-api.service` declares `After=matching-service.service dispatch-service.service` (ordering) and `Wants=matching-service.service dispatch-service.service` (best-effort pull-in at start).
- The real enforcement is an `ExecStartPre=` readiness gate that polls matching-service's and dispatch-service's `/health` (up to ~30s) before launching ride-api and **fails ride-api's start if they don't answer**. Ordering alone only guarantees the dependency *processes were launched*; the gate guarantees they are actually *listening* before ride-api goes live.
- We deliberately use `Wants=`, not `Requires=`/`BindsTo=`. Those propagate **deactivation**, so `systemctl stop matching-service` would cascade and stop ride-api. We want the opposite at runtime: ride-api stays up and **degrades gracefully** — its calls to matching-service return `502` with a structured `request_failed` log — rather than disappearing. (See the "Verify lifecycle" drill below.)

**Install / first deploy** — *reference (already done in Quick Start; shown here with per-step explanation, not to re-run)*

#### 0. Get the code onto the box and into the standard location.
```
sudo mkdir -p /opt/service-env
sudo cp -r services requirements.txt /opt/service-env/
```
#### 1. Dedicated unprivileged service account.
```
sudo useradd --system --no-create-home --shell /usr/sbin/nologin serviceenv || true
```
#### 2. Shared virtualenv + dependencies (Flask + requests).
```
sudo python3 -m venv /opt/service-env/venv
sudo /opt/service-env/venv/bin/pip install -r /opt/service-env/requirements.txt
sudo chown -R serviceenv:serviceenv /opt/service-env
```
#### 3. Service discovery must exist BEFORE the services start (they resolve
```
#    *.internal names at request time; ride-api's readiness gate needs it too).
sudo ./scripts/hosts-setup.sh
```

#### 4. Install and enable the units. Enabling ride-api pulls in matching-service and dispatch-service via Wants=,
```
#    but enable all three so each comes back independently on reboot.
sudo cp systemd/service-*.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now matching-service dispatch-service ride-api
```

**Operation** (standard Linux service commands)
```
# Status / health
systemctl status ride-api matching-service dispatch-service
sudo systemctl is-active ride-api
```
```
# Start / stop / restart
sudo systemctl start  ride-api
sudo systemctl stop   ride-api
sudo systemctl restart ride-api
```
```
# Stop everything / bring it all back
sudo systemctl stop  ride-api matching-service dispatch-service
sudo systemctl start matching-service dispatch-service ride-api   # order matters: deps first
```

**Check what's listening on the service ports** (3001 = ride-api, 3002 = matching-service, 3003 = dispatch-service)
```
sudo ss -ltnp '( sport = :3001 or sport = :3002 or sport = :3003 )'
# Each port should be owned by a "python" process under the matching unit.
# Empty output for a port = that service is not listening (see Troubleshooting).
```

**Stop / clear a port held by a stray process** (e.g. an old manual `python app.py`
left over from before systemd managed the services — this blocks the unit from binding)
```
# Preferred: stop via systemd (clean shutdown, won't auto-restart).
sudo systemctl stop matching-service
```
```
# If something OUTSIDE systemd is holding the port, find and kill it:
pkill -f 'services/matching-service/app.py'          # kill a stray matching-service process
sudo fuser -k 3002/tcp                         # or: kill whatever holds port 3002
sudo ss -ltnp '( sport = :3002 )'              # confirm the port is now free
```

**Logs** (structured JSON via journald)
```
journalctl -u ride-api -f                 # follow one service
journalctl -u ride-api -u matching-service -u dispatch-service --since "10 min ago"
# Trace one request across every service by its ID:
RID=$(curl -s http://localhost/ride-api/request-ride | grep -o '"request_id":"[^"]*"' | cut -d'"' -f4)
journalctl -u ride-api -u matching-service -u dispatch-service -o cat --since "1 min ago" | grep "$RID"
```
**Expected output** (the same `request_id` in every service — the full ride-api→matching-service→dispatch-service→ride-api journey):
```
{"...","service":"ride-api","event":"request_received","request_id":"<RID>","path":"/request-ride",...,"client_ip":"127.0.0.1"}
{"...","service":"matching-service","event":"request_received","request_id":"<RID>","path":"/find-driver",...}
{"...","service":"dispatch-service","event":"request_received","request_id":"<RID>","path":"/assign-driver",...}
{"...","service":"dispatch-service","event":"callback_sent","request_id":"<RID>","target":"ride-api",...}
{"...","service":"matching-service","event":"request_forwarded","request_id":"<RID>","target":"dispatch-service",...}
{"...","service":"ride-api","event":"callback_received","request_id":"<RID>","source_service":"dispatch-service",...}
```
Each request log line carries the standard contract fields plus **`client_ip`** (the real caller — for ride-api this comes from Nginx's `X-Forwarded-For`/`X-Real-IP`). Lifecycle is logged too: `service_started` on boot and **`service_stopping`** on `systemctl stop` (SIGTERM), so the journal shows a clean open/close for every service.

**Verify lifecycle**
```
# Boot/reboot recovery: after `sudo reboot`, all three should be active:
systemctl is-enabled ride-api matching-service dispatch-service
systemctl is-active  ride-api matching-service dispatch-service
```
**Expected output:**
```
enabled
enabled
enabled
active
active
active
```
```
# Auto-restart after failure: kill the process, it should respawn within ~2s.
sudo systemctl kill -s SIGKILL matching-service
sleep 3; systemctl is-active matching-service
```
**Expected output** (systemd respawned it with a new PID):
```
active
```
```
# Runtime dependency failure -> ride-api STAYS UP and degrades gracefully.
# (Wants=, not Requires=, so stopping matching-service does NOT cascade-stop ride-api.)
sudo systemctl stop matching-service
systemctl is-active ride-api
curl -s http://localhost/ride-api/request-ride ; echo
journalctl -u ride-api -n 20 -o cat                 # shows the structured request_failed log
sudo systemctl start matching-service                       # re-run the curl -> "status":"success"
```
**Expected output** (ride-api is still `active` and returns a clean 502 — no cascade):
```
active
{"message":"Matching service unreachable","request_id":"...","status":"error"}
{"timestamp":"...","service":"ride-api","event":"request_failed","request_id":"...","path":"/request-ride","status":502,"method":"GET","error":"..."}
```
```
# Startup readiness gate -> ride-api won't go operational until deps are healthy.
# Mask matching-service so Wants= can't auto-start it, then start ride-api: the gate waits ~30s, fails.
sudo systemctl stop ride-api
sudo systemctl mask --now matching-service
sudo systemctl start ride-api                       # blocks on the gate, then fails to start
journalctl -u ride-api -n 20                        # shows "dependencies ... not ready"
sudo systemctl unmask matching-service
sudo systemctl start matching-service ride-api             # recovers
```

## Nginx Reverse Proxy (`nginx/service-env.conf`)

Nginx is the only publicly reachable component. It listens on port 80 and exposes **ride-api only**.

**Routing**
- `GET/POST /ride-api/*` → proxied to `ride-api.internal:3001`, with the `/ride-api` prefix stripped before the request reaches Flask (e.g. `/ride-api/health` is forwarded as `/health`).
- Any other path (including attempts to reach matching-service or dispatch-service) hits the catch-all `location /` block and gets a `404`. There is no location block that forwards to `matching-service` or `dispatch-service` — Nginx has no path by which it could reach them even if asked to.

**Service discovery**
- The upstream is addressed by name (`ride-api.internal`), not by IP. Name resolution is done by the OS resolver (glibc/NSS), which on this single-VM deployment is satisfied by static `/etc/hosts` entries mapping `ride-api.internal`, `matching-service.internal`, and `dispatch-service.internal` to `127.0.0.1`. Nginx resolves the name once when it starts/reloads (no `resolver` directive is needed for static hostnames in `proxy_pass`).
- To troubleshoot discovery failures: `getent hosts ride-api.internal`, check `/etc/hosts`, then `sudo nginx -t` to confirm Nginx can parse/resolve the upstream, then `sudo systemctl reload nginx`.

**Request tracing**
- Every request gets an `X-Request-ID` (the client's header if present, otherwise a fresh one generated by Nginx's `$request_id`). It's forwarded to ride-api via `proxy_set_header` and echoed back to the client via a response header, so the same ID can be grepped across the Nginx access log and every downstream service log.

**Logging**
- Access log: `/var/log/nginx/service-env-access.log`, written as one JSON object per request (`timestamp`, `request_id`, `method`, `path`, `status`, `upstream`, `request_time`), matching the logging contract.
- Error log: `/var/log/nginx/service-env-error.log`.
- Known caveat: Nginx's `$time_iso8601` logs in the process's local timezone (e.g. `+03:00`), while the services log UTC (`Z`). Logs still correlate correctly via `request_id` regardless, but for side-by-side reading the timezone won't match. Fixing it means setting `TZ=UTC` on the Nginx process itself (a systemd `Environment=` line or `/etc/default/nginx`) — not something `service-env.conf` can control.

**Network security**
- matching-service (3002) and dispatch-service (3003) are not exposed by this proxy at all — there is no `location` block that forwards to them, so Nginx has no path by which it could reach them even if asked to.
- That only proves **Nginx** won't proxy to matching-service/dispatch-service. It does not prove they are unreachable — an instructor (or attacker) hitting `http://<vm-ip>:3002/health` directly never touches Nginx at all. Two independent layers enforce that, both applied during deploy: (1) matching-service/dispatch-service bind to `127.0.0.1` (not `0.0.0.0`), set via `BIND_HOST` in their systemd units; (2) the host firewall (`scripts/firewall-setup.sh`, ufw) default-denies inbound and explicitly blocks 3002/3003. See "Verify" below for the test that actually checks both layers from off-box.

**Deploy** — *reference (already done in Quick Start; shown here with explanation, not to re-run)*
#### 1. Service discovery must exist *before* Nginx starts - it resolves
```
#    upstream hostnames at config-load time and will refuse to start
#    with "host not found in upstream" if /etc/hosts isn't populated yet.
sudo ./scripts/hosts-setup.sh
```
#### 2. Disable the distro's default site - it ships with `server_name localhost`
```
#    and will shadow our config for any request with a "Host: localhost" header.
sudo rm -f /etc/nginx/sites-enabled/default /etc/nginx/conf.d/default.conf
```
#### 3. Deploy our config.
```
sudo cp nginx/service-env.conf /etc/nginx/conf.d/service-env.conf
sudo nginx -t
sudo systemctl reload nginx
```

**Verify**
```
# Through Nginx - only ride-api should answer:
curl -s http://localhost/ride-api/health
curl -s -o /dev/null -w '%{http_code}\n' http://localhost/matching-service
```
**Expected output:**
```
{"message":"Hello ride-api listening on 3001","port":3001,"service":"ride-api","status":"healthy"}
404
```
```
# Direct to the ports, bypassing Nginx entirely - this is the real network-security
# test the instructor will run, from off-box / using the VM's public IP:
curl --max-time 3 http://<vm-ip>:3002/health
curl --max-time 3 http://<vm-ip>:3003/health
```
**Expected output** (both must fail to reach the service):
```
curl: (28) Connection timed out after 3001 milliseconds
curl: (28) Connection timed out after 3002 milliseconds
```
If either returns a JSON response instead of timing out, Nginx is not the problem — it means matching-service/dispatch-service are bound to `0.0.0.0` and/or no firewall rule blocks the port, which is outside this config's control. ("Connection refused" instead of "timed out" means the firewall is off and only the loopback bind is protecting you — re-run `sudo ./scripts/firewall-setup.sh`.)

## Why the trigger endpoint is `GET`

`GET /ride-api/request-ride` starts the flow. `GET` is what the Service API contract specifies, and it's safe here: the request carries **no body** and is **safe to re-issue** (re-running it just re-traces the chain). The only state-changing hop — dispatch-service notifying ride-api — is a **`POST`** to `/driver-assigned`. ride-api also accepts `POST /request-ride` as an alias, so a demo can drive the flow with either verb.

## Troubleshooting & Failure Scenarios

Each row is a failure the system is expected to handle; capture the real `curl` + `journalctl` output into [docs/evidence/EVIDENCE.md](docs/evidence/EVIDENCE.md).

| Symptom / scenario | How to investigate | Expected behavior |
|--------------------|--------------------|-------------------|
| **"Matching service unreachable"** from ride-api | `systemctl is-active matching-service`; `sudo ss -ltnp '( sport = :3002 )'`; `getent hosts matching-service.internal` | matching-service down, port not bound, or name not resolving. Restart it / run `hosts-setup.sh`. |
| **Stop a dependency** (`systemctl stop matching-service`) | hit `/ride-api/request-ride`; `journalctl -u ride-api` | ride-api stays **active**, returns `502`, logs `request_failed`. No cascade (it's `Wants=`, not `Requires=`). |
| **Service won't start** | `systemctl status ride-api`; `journalctl -u ride-api -n 40` | ride-api's readiness gate logs `dependencies … not ready` if matching-service/dispatch-service aren't healthy. |
| **Crash recovery** | `sudo systemctl kill -s SIGKILL matching-service; sleep 3; systemctl is-active matching-service` | `active` again within ~2s (`Restart=on-failure`). |
| **Reboot recovery** | `sudo reboot`; reconnect; `systemctl is-active ride-api matching-service dispatch-service` | all `active`, no manual action. |
| **Invalid route** | `curl -s http://localhost/ride-api/nope` | structured JSON `404`, logged as `route_not_found`. |
| **Nginx won't reload** | `sudo nginx -t` | `host not found in upstream` ⇒ `/etc/hosts` missing; run `hosts-setup.sh`. |
| **matching-service/dispatch-service reachable from off-box** | from the **host**: `curl --connect-timeout 3 http://<vm-ip>:3002/health` | must fail; if not, check `BIND_HOST` and `ufw status`. |

The external-exposure and host-forwarding checks must be run **from the host** (they catch VM port-forward / NAT leaks). The full claim→command→expected matrix and where to paste outputs is in [docs/evidence/EVIDENCE.md](docs/evidence/EVIDENCE.md).
