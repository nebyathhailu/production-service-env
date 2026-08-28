# Proof Pack — captured evidence

## AWS IaC environment (account `240462142849`) — captured 2026-08-28

This is the pack to submit with [production-readiness.md](../production-readiness.md).
CLI profile: `devops-lab-new`. Cluster: `devops-g1-iac-cluster`.
ALB: `devops-g1-iac-alb-207582331.us-east-1.elb.amazonaws.com`.

### Services running

```
devops-g1-iac-ride-api-svc            desired 2  running 2  ACTIVE  task-definition .../devops-g1-iac-ride-api:2
devops-g1-iac-matching-service-svc    desired 1  running 1  ACTIVE  task-definition .../devops-g1-iac-matching-service:1
devops-g1-iac-dispatch-service-svc    desired 1  running 1  ACTIVE  task-definition .../devops-g1-iac-dispatch-service:1
```

Images (never `latest`):

```
240462142849.dkr.ecr.us-east-1.amazonaws.com/devops-g1-ride-api:15e1aea-amd64
240462142849.dkr.ecr.us-east-1.amazonaws.com/devops-g1-matching-service:f4d49be-amd64
240462142849.dkr.ecr.us-east-1.amazonaws.com/devops-g1-dispatch-service:570e4ab
```

ALB target group `devops-g1-iac-svc-a-tg`: both IP targets healthy (`10.1.10.10` us-east-1a, `10.1.11.157` us-east-1b), port 3001.

### Happy path through the ALB

```
GET /health → 200
{"dependencies":{"matching-service":"ok"},"status":"healthy","service":"ride-api","port":3001,...}

POST /request-ride  X-Request-ID: SUBMIT-TRACE-001  → 200
{"message":"Request completed successfully","request_id":"SUBMIT-TRACE-001","status":"success"}
```

Same `request_id` + `trace_id` (`5a562ccdc74e382eb153c9e5661148b7`) on every hop, including the callback:

```
ride-api     request_received   POST /request-ride
matching     request_received   GET  /find-driver
dispatch     request_received   GET  /assign-driver
dispatch     callback_sent      target ride-api  downstream_status 200
ride-api     callback_received  POST /driver-assigned  source_service dispatch-service
matching     request_forwarded  target dispatch-service  downstream_status 200
ride-api     request_forwarded  target matching-service
```

### Security groups (reference, not CIDR)

| Destination SG | Port | Allowed sources |
|---|---|---|
| `devops-g1-iac-alb-sg` (`sg-0333a8fc33908f83d`) | 80 | `0.0.0.0/0` |
| `devops-g1-iac-ride-api-sg` (`sg-04cb87c3a8a99573d`) | 3001 | ALB SG + dispatch SG (callback) |
| `devops-g1-iac-matching-service-sg` (`sg-05d06e8ca1b8d94ce`) | 3002 | ride-api SG only |
| `devops-g1-iac-dispatch-service-sg` (`sg-07b992f7224a76e9a`) | 3003 | matching-service SG only |

No `0.0.0.0/0` on 3001/3002/3003. No ride-api → dispatch-service ingress rule.

### GitHub Actions OIDC

```
oidc-provider  arn:aws:iam::240462142849:oidc-provider/token.actions.githubusercontent.com
role           arn:aws:iam::240462142849:role/devops-g1-github-actions-role
               created 2026-08-28T06:15:58Z
```

Repo variable `AWS_ACCOUNT_ID=240462142849`. Workflow: `.github/workflows/container-ci-cd.yml`.

---

# Original VM proof pack


A unit file or README claim is **not proof until its output is captured.** This
file holds real terminal transcripts proving each architecture/security claim
from the correct network position. Regenerate the inside-VM half any time with:

```
./scripts/collect-evidence.sh      # writes docs/evidence/evidence-<timestamp>.txt
```

The **external** and **host-forwarding** rows below cannot be proven from inside
the VM — they must be run from the **host machine** (this is the point: it
catches Multipass NAT/port-forward leaks, bridge surprises, or cloud SG gaps).

| Claim | Run from | Command | Expected |
|-------|----------|---------|----------|
| Socket binding | inside VM | `sudo ss -tulpen \| grep -E ':80\|:3001\|:3002\|:3003'` | Nginx on `:80`; A/B/C on `127.0.0.1` only |
| Firewall state | inside VM | `sudo ufw status verbose` | only 22 + 80 inbound; 3002/3003 denied |
| External exposure | **host** | `curl --connect-timeout 3 http://<VM_IP>:3002/health` | B/C fail externally; `:80` works |
| Host forwarding | **host** | `curl --connect-timeout 3 http://127.0.0.1:3002/health` | fails unless VM runtime forwards it |
| Happy-path trace | via Nginx | curl `/ride-api/request-ride`, then grep the `request_id` | same ID in Nginx + ride-api + matching-service + dispatch-service |
| Failure behavior | inside | stop B, hit public endpoint, inspect logs | A stays up, returns 502, `request_failed` logged |
| Lifecycle | inside VM | `pkill`/reboot, then `systemctl status` | systemd restarts; survives reboot |

---

## Inside-VM evidence

> Paste the latest `evidence-<timestamp>.txt` produced by `collect-evidence.sh`,
> or link the committed file. Example placeholder below — replace with real output.

```
<paste output of ./scripts/collect-evidence.sh here>
```

## Host-side evidence (run on the machine hosting the VM)

Replace `<VM_IP>` with the address from `multipass info <vm-name>` (or `hostname -I`).

```console
# Public entry point works:
$ curl --connect-timeout 3 -s -o /dev/null -w '%{http_code}\n' http://<VM_IP>/ride-api/health
<paste: expect 200>

# Internal services are NOT reachable from off-box:
$ curl --connect-timeout 3 http://<VM_IP>:3002/health
<paste: expect "Connection timed out" (ufw) or "Connection refused" (loopback bind)>

$ curl --connect-timeout 3 http://<VM_IP>:3003/health
<paste: expect timeout/refused>

# Loopback on the host must NOT reach the VM's internal ports (no stray forward):
$ curl --connect-timeout 3 http://127.0.0.1:3002/health
<paste: expect fail>
```

## Lifecycle evidence (reboot + crash recovery)

```console
# Crash recovery — kill the process, systemd respawns it:
$ sudo systemctl kill -s SIGKILL matching-service ; sleep 3 ; systemctl is-active matching-service
<paste: expect "active">

# Reboot recovery — after `sudo reboot` and reconnecting:
$ systemctl is-enabled ride-api matching-service dispatch-service
<paste: expect enabled x3>
$ systemctl is-active ride-api matching-service dispatch-service
<paste: expect active x3>
```
