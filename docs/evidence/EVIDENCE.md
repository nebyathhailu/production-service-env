# Proof Pack — captured evidence

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
| Happy-path trace | via Nginx | curl `/service-a/greet-service-b`, then grep the `request_id` | same ID in Nginx + A + B + C |
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
$ curl --connect-timeout 3 -s -o /dev/null -w '%{http_code}\n' http://<VM_IP>/service-a/health
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
$ sudo systemctl kill -s SIGKILL service-b ; sleep 3 ; systemctl is-active service-b
<paste: expect "active">

# Reboot recovery — after `sudo reboot` and reconnecting:
$ systemctl is-enabled service-a service-b service-c
<paste: expect enabled x3>
$ systemctl is-active service-a service-b service-c
<paste: expect active x3>
```
