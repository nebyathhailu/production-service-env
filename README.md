# production-service-env
A production-style microservices environment with Nginx reverse proxy, systemd lifecycle management, structured logging, and request tracing.

## Services & systemd Lifecycle (`systemd/*.service`)

The three Python/Flask services run as systemd units so they start on boot, restart on failure, log to journald, and honour the A→depends-on→B,C ordering.

**Deployment layout**
- Code: `/opt/service-env/services/service-{a,b,c}/`
- Shared virtualenv: `/opt/service-env/venv/`
- Runs as the unprivileged system user `serviceenv` (no login, no home) — keeps services off `root` and lets the unit hardening (`ProtectHome`, `ProtectSystem`) apply.

**Dependency management** (assignment requirement: A must not start before B and C, and must not become operational until they are available)
- `service-a.service` declares `After=service-b.service service-c.service` and `Wants=service-b.service service-c.service` — ordering + "try to start the deps first."
- It also has an `ExecStartPre=` readiness gate that polls B's and C's `/health` (up to ~30s) before launching A. Ordering alone only guarantees the dependency *processes were launched*; the gate guarantees they are actually *listening* before A goes live.
- **Why `Wants=` and not `Requires=`:** we initially used `Requires=`, but `Requires=` propagates *deactivation* as well as activation — if B or C is later stopped or crashes, systemd automatically tears down A too, taking the public entry point down along with one internal dependency. We confirmed this live: `systemctl stop service-b` was immediately followed by systemd stopping `service-a` on its own. `Wants=` keeps the startup ordering/pull-in behavior without that runtime coupling, so A now stays up when a dependency goes down later and lets its own error handling return a graceful `502` instead of disappearing entirely (verified: `service-a` stays `active` while `service-b` is `inactive`, and the request through Nginx returns `{"message":"Service B unreachable", ...}` with a structured `request_failed` log entry).

**Install / first deploy** (run as root on the VM)
```
# 0. Get the code onto the box and into the standard location.
sudo mkdir -p /opt/service-env
sudo cp -r services requirements.txt /opt/service-env/

# 1. Dedicated unprivileged service account.
sudo useradd --system --no-create-home --shell /usr/sbin/nologin serviceenv || true

# 2. Shared virtualenv + dependencies (Flask + requests).
sudo python3 -m venv /opt/service-env/venv
sudo /opt/service-env/venv/bin/pip install -r /opt/service-env/requirements.txt
sudo chown -R serviceenv:serviceenv /opt/service-env

# 3. Service discovery must exist BEFORE the services start (they resolve
#    *.internal names at request time; Service A's readiness gate needs it too).
sudo ./scripts/hosts-setup.sh

# 3b. Firewall: defense-in-depth backstop for B/C's bind-address protection.
#     Allows only SSH (22) and Nginx's HTTP (80) in; everything else denied.
sudo ./scripts/firewall-setup.sh

# 4. Install and enable the units. Enabling A pulls in B and C via Wants=,
#    but enable all three so each comes back independently on reboot.
sudo cp systemd/service-*.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now service-b service-c service-a
```

**Operation** (standard Linux service commands)
```
# Status / health
systemctl status service-a service-b service-c
sudo systemctl is-active service-a

# Start / stop / restart
sudo systemctl start  service-a
sudo systemctl stop   service-a
sudo systemctl restart service-a

# Stop everything / bring it all back
sudo systemctl stop  service-a service-b service-c
sudo systemctl start service-b service-c service-a   # order matters: deps first
```

**Logs** (structured JSON via journald)
```
journalctl -u service-a -f                 # follow one service
journalctl -u service-a -u service-b -u service-c --since "10 min ago"
journalctl -u service-a -o cat | grep '"request_id":"<id>"'   # trace one request
```

**Verify lifecycle**
```
# Boot/reboot recovery: after `sudo reboot`, all three should be active:
systemctl is-enabled service-a service-b service-c   # -> enabled
systemctl is-active  service-a service-b service-c   # -> active

# Auto-restart after failure: kill the process, it should respawn within ~2s.
sudo systemctl kill -s SIGKILL service-b
sleep 3; systemctl is-active service-b               # -> active (new PID)

# Dependency gate at startup: if a dep is down when A tries to (re)start,
# the ExecStartPre readiness gate blocks (~30s) then fails the start attempt.
sudo systemctl stop service-b
sudo systemctl restart service-a                     # blocks on readiness gate, then fails
journalctl -u service-a -n 20                        # shows "dependencies ... not ready"
sudo systemctl start service-b && sudo systemctl start service-a   # recovers

# Graceful degradation at runtime: stop a dependency WITHOUT touching A.
# A must stay active and degrade gracefully, not go down with it.
sudo systemctl stop service-b
systemctl is-active service-a service-b service-c    # -> active inactive active
curl -i --max-time 8 http://localhost/service-a/greet-service-b   # -> 502, JSON body, not a hang/crash
journalctl -u service-a -n 3                          # shows a structured "request_failed" entry
sudo systemctl start service-b                        # recovers, next request succeeds
```

## Nginx Reverse Proxy (`nginx/service-env.conf`)

Nginx is the only publicly reachable component. It listens on port 80 and exposes **Service A only**.

**Routing**
- `GET/POST /service-a/*` → proxied to `service-a.internal:3001`, with the `/service-a` prefix stripped before the request reaches Flask (e.g. `/service-a/health` is forwarded as `/health`).
- Any other path (including attempts to reach Service B or C) hits the catch-all `location /` block and gets a `404`. There is no location block that forwards to `service-b` or `service-c` — Nginx has no path by which it could reach them even if asked to.

**Service discovery**
- The upstream is addressed by name (`service-a.internal`), not by IP. Name resolution is done by the OS resolver (glibc/NSS), which on this single-VM deployment is satisfied by static `/etc/hosts` entries mapping `service-a.internal`, `service-b.internal`, and `service-c.internal` to `127.0.0.1`. Nginx resolves the name once when it starts/reloads (no `resolver` directive is needed for static hostnames in `proxy_pass`).
- To troubleshoot discovery failures: `getent hosts service-a.internal`, check `/etc/hosts`, then `sudo nginx -t` to confirm Nginx can parse/resolve the upstream, then `sudo systemctl reload nginx`.

**Request tracing**
- Every request gets an `X-Request-ID` (the client's header if present, otherwise a fresh one generated by Nginx's `$request_id`). It's forwarded to Service A via `proxy_set_header` and echoed back to the client via a response header, so the same ID can be grepped across the Nginx access log and every downstream service log.

**Logging**
- Access log: `/var/log/nginx/service-env-access.log`, written as one JSON object per request (`timestamp`, `request_id`, `method`, `path`, `status`, `upstream`, `request_time`), matching the logging contract.
- Error log: `/var/log/nginx/service-env-error.log`.
- Known caveat: Nginx's `$time_iso8601` logs in the process's local timezone (e.g. `+03:00`), while the services log UTC (`Z`). Logs still correlate correctly via `request_id` regardless, but for side-by-side reading the timezone won't match. Fixing it means setting `TZ=UTC` on the Nginx process itself (a systemd `Environment=` line or `/etc/default/nginx`) — not something `service-env.conf` can control.

**Network security**
- Service B (3002) and Service C (3003) are not exposed by this proxy at all — there is no `location` block that forwards to them, so Nginx has no path by which it could reach them even if asked to.
- That only proves **Nginx** won't proxy to B/C. It does not prove B/C are unreachable — an instructor (or attacker) hitting `http://<vm-ip>:3002/health` directly never touches Nginx at all. Two independent layers actually enforce that:
  1. **Bind-address**: B and C bind to `127.0.0.1`, not `0.0.0.0` (set via `BIND_HOST` in their systemd units), so nothing outside the VM can reach those ports regardless of firewall state.
  2. **Firewall (`scripts/firewall-setup.sh`, `ufw`)**: default-deny on incoming, with only SSH (22) and Nginx's HTTP (80) explicitly allowed. This is the backstop for layer 1 — if `BIND_HOST` ever drifts to `0.0.0.0` by accident, the firewall still blocks external access instead of silently exposing B/C.
- Run `sudo ./scripts/firewall-setup.sh` once per VM to apply this. See "Verify" below for the test that checks both layers are actually working, not just configured.

**Deploy**
```
# 1. Service discovery must exist *before* Nginx starts - it resolves
#    upstream hostnames at config-load time and will refuse to start
#    with "host not found in upstream" if /etc/hosts isn't populated yet.
sudo ./scripts/hosts-setup.sh

# 2. Disable the distro's default site - it ships with `server_name localhost`
#    and will shadow our config for any request with a "Host: localhost" header.
sudo rm -f /etc/nginx/sites-enabled/default /etc/nginx/conf.d/default.conf

# 3. Deploy our config.
sudo cp nginx/service-env.conf /etc/nginx/conf.d/service-env.conf
sudo nginx -t
sudo systemctl reload nginx
```

**Verify**
```
# Through Nginx - only Service A should answer:
curl -i http://localhost/service-a/health      # expect 200
curl -i http://localhost/service-b              # expect Nginx's JSON 404 (proves no route exists in Nginx)

# Direct to the ports, bypassing Nginx entirely - this is the real network-security
# test the instructor will run, from off-box / using the VM's public IP:
curl --max-time 3 http://<vm-ip>:3002/health    # expect: connection timed out (ufw dropping it)
curl --max-time 3 http://<vm-ip>:3003/health    # expect: connection timed out (ufw dropping it)

# Confirm the firewall itself is the active layer (not just bind-address):
sudo ufw status verbose                          # expect: active, default deny (incoming),
                                                  #   only 22/tcp and 80/tcp explicitly allowed
```
If either of the `curl` commands return a response instead of timing out, something regressed — either B/C started binding to `0.0.0.0` instead of `127.0.0.1`, or `ufw` is inactive (`sudo ufw status`). If you only get "connection refused" instead of "timed out," the firewall isn't active and you're seeing bind-address-only protection — re-run `sudo ./scripts/firewall-setup.sh`.

**One-shot sanity check**
```
./scripts/test-end-to-end.sh
```
Runs five assertions in one go - Service A health, the full A→B→C→A flow, Service B/C not routable through Nginx, and structured JSON 404s on unknown routes - and exits non-zero if anything fails. Good to run right after deploying, after a reboot, or right before the demo.
