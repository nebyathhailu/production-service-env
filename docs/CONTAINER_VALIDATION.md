# Container Validation

Branch: `feature/docker-compose`
Commit used for this validation run: `3902184d380bea8db5899ff3358fa3eab8c280f1`

> **Note:** this transcript predates the `service-a`/`service-b`/`service-c` → `ride-api`/
> `matching-service`/`dispatch-service` rename. Service identifiers below (`service-a`, `/greet-service-b`,
> etc.) reflect the naming at the time this run was captured, not the current naming — see
> `services/*/app.py`, `docker-compose.yml`, and the README for the current names. Kept as-is because
> this file documents a real captured run, not a template to update in place.

All commands below were run for real against the actual `docker-compose.yml` in this repo, not reconstructed from memory. Output is copied verbatim (timestamps will differ on re-run).

## 1. Start the system

```
$ docker compose up --build -d
```
```
 Network production-service-env_appnet  Created
 Container production-service-env-service-c-1  Created
 Container production-service-env-service-b-1  Created
 Container production-service-env-service-a-1  Created
 Container production-service-env-nginx-1  Created
 Container production-service-env-service-b-1  Starting
 Container production-service-env-service-c-1  Starting
 Container production-service-env-service-b-1  Started
 Container production-service-env-service-c-1  Started
 Container production-service-env-service-b-1  Waiting
 Container production-service-env-service-c-1  Waiting
 Container production-service-env-service-b-1  Healthy
 Container production-service-env-service-c-1  Healthy
 Container production-service-env-service-a-1  Starting
 Container production-service-env-service-a-1  Started
 Container production-service-env-service-a-1  Waiting
 Container production-service-env-service-a-1  Healthy
 Container production-service-env-nginx-1  Starting
 Container production-service-env-nginx-1  Started
```

Note the start order: **B and C start and become `Healthy` first, then A starts, then Nginx starts last** - this is `depends_on: condition: service_healthy` in `docker-compose.yml` doing the same job the VM version's systemd `ExecStartPre` readiness gate did. Nobody had to wait manually; Compose enforced the dependency itself.

## 2. Confirm containers are running

```
$ docker compose ps
```
```
NAME                                  IMAGE                              SERVICE     STATUS                    PORTS
production-service-env-nginx-1       nginx:1.27-alpine                  nginx       Up 2 minutes              0.0.0.0:8080->80/tcp, :::8080->80/tcp
production-service-env-service-a-1   production-service-env-service-a   service-a   Up 2 minutes (healthy)    3001/tcp
production-service-env-service-b-1   production-service-env-service-b   service-b   Up 28 seconds (healthy)   3002/tcp
production-service-env-service-c-1   production-service-env-service-c   service-c   Up 2 minutes (healthy)    3003/tcp
```

All four running. Look at the `PORTS` column: Nginx shows `0.0.0.0:8080->80/tcp` (published to the host); Service A/B/C show only `3001/tcp`, `3002/tcp`, `3003/tcp` with **no host mapping at all**. That's the actual proof "only Nginx publishes a host port" - not just a claim in the compose file, but the live Docker state.

## 3. Test public entry point

```
$ curl -i http://localhost:8080/service-a/health
```
```
HTTP/1.1 200 OK
Server: nginx
Content-Type: application/json
Content-Length: 101
X-Request-ID: 35a4efcd7db08bc3e0bf56cd7b447c1d

{"message":"Hello service-a listening on 3001","port":3001,"service":"service-a","status":"healthy"}
```

`200`, healthy. Note exactly one `X-Request-ID` header - `nginx/docker-compose.conf` strips Service A's own copy (`proxy_hide_header`) and supplies a single canonical one, same fix as the VM version.

## 4. Prove B and C are not directly exposed

```
$ curl -i --connect-timeout 3 http://localhost:3002/health
$ curl -i --connect-timeout 3 http://localhost:3003/health
```
```
curl: (7) Failed to connect to localhost port 3002 after 0 ms: Connection refused
curl: (7) Failed to connect to localhost port 3003 after 0 ms: Connection refused
```

Refused on both - nothing is listening on the host for these ports at all, since `docker-compose.yml` gives Service B/C no `ports:` entry.

## 5. Prove internal service discovery works

```
$ docker compose exec service-a curl -i http://service-b:3002/health
$ docker compose exec service-b curl -i http://service-c:3003/health
```
```
HTTP/1.1 200 OK
Server: Werkzeug/3.1.8 Python/3.12.13
Content-Type: application/json
Content-Length: 101

{"message":"Hello service-b listening on 3002","port":3002,"service":"service-b","status":"healthy"}
---
HTTP/1.1 200 OK
Server: Werkzeug/3.1.8 Python/3.12.13
Content-Type: application/json
Content-Length: 101

{"message":"Hello service-c listening on 3003","port":3003,"service":"service-c","status":"healthy"}
```

Both `200` - plain Compose service names (`service-b`, `service-c`) resolve correctly from inside other containers via Docker's built-in DNS. No `/etc/hosts` script needed here (that was the VM-specific mechanism); this is the "Compose DNS service names" row from the assignment's Key Concept Shift table, confirmed working.

## 6. Trace one request

```
$ curl -s http://localhost:8080/service-a/greet-service-b -H "X-Request-ID: demo-container-001"
```
```
{"message":"Request completed successfully","request_id":"demo-container-001","status":"success"}
```

```
$ docker compose logs | grep demo-container-001
```
```
service-b-1  | {"timestamp": "2026-06-26T17:26:46Z", "service": "service-b", "event": "request_received", "request_id": "demo-container-001", "path": "/greet", "status": 200, "method": "GET"}
service-b-1  | {"timestamp": "2026-06-26T17:26:46Z", "service": "service-b", "event": "request_forwarded", "request_id": "demo-container-001", "path": "/greet", "status": 200, "method": "GET", "target": "service-c", "downstream_status": 200}
service-c-1  | {"timestamp": "2026-06-26T17:26:46Z", "service": "service-c", "event": "request_received", "request_id": "demo-container-001", "path": "/greet-c", "status": 200, "method": "GET"}
service-c-1  | {"timestamp": "2026-06-26T17:26:46Z", "service": "service-c", "event": "callback_sent", "request_id": "demo-container-001", "path": "/greet-c", "status": 200, "method": "GET", "target": "service-a", "downstream_status": 200}
nginx-1      | {"timestamp":"2026-06-26T17:26:46+00:00","request_id":"demo-container-001","method":"GET","path":"/service-a/greet-service-b","status":200,"upstream":"service-a:3001","request_time":0.013}
service-a-1  | {"timestamp": "2026-06-26T17:26:46Z", "service": "service-a", "event": "request_received", "request_id": "demo-container-001", "path": "/greet-service-b", "status": 200, "method": "GET"}
service-a-1  | {"timestamp": "2026-06-26T17:26:46Z", "service": "service-a", "event": "callback_received", "request_id": "demo-container-001", "path": "/greeting-rcvd", "status": 200, "source_service": "service-c", "message": "Greeting processed"}
service-a-1  | {"timestamp": "2026-06-26T17:26:46Z", "service": "service-a", "event": "request_forwarded", "request_id": "demo-container-001", "path": "/greet-service-b", "status": 200, "method": "GET", "target": "service-b"}
```

The same `demo-container-001` appears in Nginx, Service A, Service B, and Service C - all via plain `docker compose logs`, no journald/file-tailing needed.

## 7. Stop Service B and observe failure

```
$ docker compose stop service-b
$ curl -i http://localhost:8080/service-a/greet-service-b -H "X-Request-ID: fail-service-b-001"
```
```
HTTP/1.1 502 BAD GATEWAY
Server: nginx
Content-Type: application/json
Content-Length: 87
X-Request-ID: fail-service-b-001

{"message":"Service B unreachable","request_id":"fail-service-b-001","status":"error"}
```

Clean failure: a real HTTP `502` with a readable JSON body, not a hang or a crash.

```
$ docker compose logs service-a | grep fail-service-b-001
```
```
service-a-1  | {"timestamp": "2026-06-26T17:27:10Z", "service": "service-a", "event": "request_received", "request_id": "fail-service-b-001", "path": "/greet-service-b", "status": 200, "method": "GET"}
service-a-1  | {"timestamp": "2026-06-26T17:27:10Z", "service": "service-a", "event": "request_failed", "request_id": "fail-service-b-001", "path": "/greet-service-b", "status": 502, "method": "GET", "error": "HTTPConnectionPool(host='service-b', port=3002): Max retries exceeded with url: /greet (Caused by NameResolutionError(\"HTTPConnection(host='service-b', port=3002): Failed to resolve 'service-b' ([Errno -3] Temporary failure in name resolution)\"))"}
```

Service A logged the failure with full context (`request_id`, `path`, `status`, the real exception).

**Worth noting - a genuine runtime difference from the VM version:** on the VM, stopping Service B left `/etc/hosts` intact, so the failure mode was "connection refused" (the name still resolved, the port just wasn't listening). In Compose, stopping a container also removes its DNS entry, so the failure mode here is "Temporary failure in name resolution" instead. Same outcome (Service A degrades gracefully, returns 502, logs it), different underlying error - exactly the kind of runtime-specific detail the assignment asks you to notice when the same production behavior moves from systemd/VM to containers.

Recovery:

```
$ docker compose start service-b
$ curl -i http://localhost:8080/service-a/greet-service-b -H "X-Request-ID: recovered-001"
```
```
HTTP/1.1 200 OK
Server: nginx
Content-Type: application/json
Content-Length: 93
X-Request-ID: recovered-001

{"message":"Request completed successfully","request_id":"recovered-001","status":"success"}
```

Back to `200` immediately after restarting Service B - no other manual steps required.

## Summary

| Test | Result |
|---|---|
| 1. Start the system | Pass - correct dependency-gated startup order |
| 2. Containers running | Pass - all 4 healthy, B/C show no published port |
| 3. Public entry point | Pass - 200, single X-Request-ID |
| 4. B/C not directly exposed | Pass - connection refused on both |
| 5. Internal service discovery | Pass - Compose DNS names resolve, 200 |
| 6. Request tracing | Pass - same ID across Nginx + all 3 services |
| 7. Stop B, observe + recover | Pass - graceful 502, logged, clean recovery |
