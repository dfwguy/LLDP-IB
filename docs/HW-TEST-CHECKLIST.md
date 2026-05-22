# LLDPq-IB First-Deployment HW Test Checklist

This checklist guides an operator (or AI assistant) through validating
LLDPq-IB against a real NVIDIA MLNX-OS InfiniBand fabric for the first time.
Run through every section in order; do not skip "PASS" gates.

The goal is to confirm:

1. The container starts and self-heals correctly.
2. SSH key auth to switches works.
3. `ib-monitor.sh` produces non-empty JSON outputs.
4. All web UI pages render real fabric data without hardcoded references.
5. Optional UFM integration works when `UFM_URL` / `UFM_TOKEN` are supplied.

## 0. Prerequisites

| Item | How to verify |
|------|----------------|
| At least 1 amd64 host with Docker installed | `docker --version` |
| Network reachability host → switch mgmt IPs | `ping <switch-ip>` |
| MLNX-OS admin password (default `admin`) | login via `ssh admin@<switch>` |
| (Optional) UFM REST endpoint + Basic-auth token | `curl https://ufm/ufmRest/app/ufm_version` |
| (Optional) DHCP relay covers the switch mgmt subnet | only needed for ZTP |

Bring at least **one IB switch** and ideally **one HCA-equipped host** so
`ib ibnetdiscover` reports a non-empty graph.

## 1. Build / Pull the image

Build from source:

```bash
git clone https://github.com/aliaydemir/lldpq-ib-src.git
cd lldpq-ib-src
./docker/docker-build.sh
```

PASS gate: image listed by `docker images | grep lldpq-ib`, size ~700–900 MB.

Alternatively, if a published image is available:

```bash
docker pull registry.example.com/lldpq/lldpq-ib:latest
```

## 2. Prepare devices.yaml

Edit a local `devices.yaml` to match your fabric. Minimum example:

```yaml
defaults:
  username: admin

devices:
  10.10.100.10: ib-spine-01 @spine
  10.10.100.20: ib-leaf-01  @leaf
```

PASS gate: `python3 -c "import yaml; yaml.safe_load(open('devices.yaml'))"`
exits 0.

## 3. Launch the container

```bash
docker run -d --name lldpq-ib \
  --network host --privileged \
  -v $(pwd)/devices.yaml:/home/lldpq/lldpq/devices.yaml \
  -v lldpq-ib-data:/home/lldpq/lldpq/monitor-results \
  -v lldpq-ib-ssh:/home/lldpq/.ssh \
  lldpq-ib:latest
```

PASS gates:

| Check | Command |
|-------|---------|
| Container running | `docker ps --filter name=lldpq-ib` |
| Web UI reachable | `curl -s -o /dev/null -w "%{http_code}" http://localhost/` returns `200` |
| Cron registered | `docker exec lldpq-ib crontab -u lldpq -l` shows the lldpq + lldpq-trigger lines |
| fcgiwrap up | `docker exec lldpq-ib pgrep fcgiwrap` returns a PID |

Tail container logs while the next steps run:

```bash
docker logs -f lldpq-ib
```

## 4. SSH key setup

```bash
# Generate a key inside the container (one-time)
docker exec lldpq-ib ssh-keygen -t ed25519 -N '' -f /home/lldpq/.ssh/id_ed25519
# Read the public key:
docker exec lldpq-ib cat /home/lldpq/.ssh/id_ed25519.pub
```

On each switch (MLNX-OS CLI):

```text
switch# configure terminal
switch (config) # ssh client user admin authorized-key sshv2 "ssh-ed25519 AAAA... lldpq@container"
switch (config) # write memory
```

PASS gate: from inside the container,

```bash
docker exec -u lldpq lldpq-ib ssh -o BatchMode=yes admin@<switch-ip> "show version | head -1"
```

returns the MLNX-OS version line (not a password prompt).

## 5. First cron pass (data collection)

Force-run the monitor without waiting for the 10-minute cron:

```bash
docker exec -u lldpq lldpq-ib /usr/local/bin/lldpq -
```

PASS gates inside `/home/lldpq/lldpq/monitor-results/`:

| File | Should contain |
|------|----------------|
| `assets.ini` (in `/var/www/html/`) | One row per device, last column `1` for reachable |
| `ib_topology.json` | `total_nodes`, `total_links` > 0, switches + hcas populated |
| `ib_sm_status.json` | `master_count >= 1`, `has_master: true` |
| `ib_link_errors.json` | `critical_count`, `warning_count`, `flapping_1h` keys present |
| `ib_pkey.json` | `total_pkeys >= 1` |
| `transceiver_inventory.json` | `total_modules > 0` if any transceivers populated |

Validate JSON shape:

```bash
docker exec lldpq-ib python3 -c "
import json
for n in ('ib_topology','ib_sm_status','ib_link_errors','ib_pkey','ib_multicast','ib_qos','ib_sharp_status','transceiver_inventory'):
    d = json.load(open(f'/home/lldpq/lldpq/monitor-results/{n}.json'))
    print(n, '->', d.get('summary', {}))
"
```

## 6. UI smoke (every sidebar item)

Open `http://<lldpq-host>/` in a browser. Login as `admin`/`admin` and
immediately change the password.

Per-page acceptance:

| Sidebar item | Page | Expected real-fabric content |
|--------------|------|------------------------------|
| Fabric | `start.html` | Cards show non-zero switches/hcas/links and SM master GUID |
| Search | `search.html` | Typing a GUID prefix narrows the result list |
| Tracepath | `tracepath.html` | Selecting two HCAs draws a BFS path |
| Telemetry | `telemetry.html` | UFM banner reflects state; BER chart loads if UFM configured |
| Provision | `provision.html` | DHCP / ZTP / SSH-Setup tabs render without console errors |
| Assets | `assets.html` | Devices listed with model + serial after the first cron pass |
| Details | `device.html` | Pick a device → Overview / Ports / Optical / SM tabs all populate |
| Configs | `dev-conf.html` | After `get-conf` runs, switch running-config text appears |
| IB Discovery → Results | `lldp.html` | Nodes table populated from `ib_topology.json` |
| IB Discovery → Problems | `lldp-problem.html` | Empty if fabric clean; warnings if unreachable / critical |
| SM Status | `sm-status.html` | Master + standby cards correct |
| Link Errors | `ib-link-errors.html` | Top-N per-port counter table |
| P_Key | `pkey-report.html` | Partitions listed; cross-device consistency = OK |
| Multicast | `multicast-report.html` | At least 1 default IPoIB group (0xc000…) |
| QoS | `qos-report.html` | SL/VL grid renders |
| SHARP | `sharp-report.html` | Conditional menu item only appears if SHARP enabled |
| Transceiver | `transceiver.html` | Per-module vendor/PN/SN/FW table |
| UFM | `ufm-status.html` | "UFM not configured" or real status if `UFM_URL` set |
| Logs | `/monitor-results/log-analysis.html` | Counts per severity, recent entries listed |
| Topology | `topology/main.html` | cytoscape graph renders, layout selector works |

Browser console must be 0 errors for each page. Network tab: no 404 / 500
responses for `/monitor-results/ib_*.json`, `/ib-api.sh?action=*`, or
`/ufm-api.sh?action=*` when applicable.

## 7. UFM integration (optional)

If you have a UFM cluster:

```bash
docker rm -f lldpq-ib
docker run -d --name lldpq-ib --network host --privileged \
  -v $(pwd)/devices.yaml:/home/lldpq/lldpq/devices.yaml \
  -v lldpq-ib-data:/home/lldpq/lldpq/monitor-results \
  -v lldpq-ib-ssh:/home/lldpq/.ssh \
  -e UFM_URL="https://ufm.example.com/ufmRest" \
  -e UFM_TOKEN="$(echo -n 'admin:ufmpassword' | base64)" \
  -e UFM_VERIFY_TLS=false \
  lldpq-ib:latest
```

PASS gates:

- `ufm-status.html` shows "UFM connected" with a version badge
- Alerts table populates (or "no active alerts" if fabric is healthy)
- Topology cross-check lists "common GUIDs" > 0
- `telemetry.html` → BER History card loads, dropdown lists switches, Chart.js
  line chart renders with logarithmic Y axis for `ber_total_phy`

## 8. Alerts dry-run (optional)

1. Edit `lldpq/notifications.yaml`: set `notifications.enabled: true`,
   configure a Slack webhook.
2. From the container:
   ```bash
   docker exec -u lldpq lldpq-ib python3 /home/lldpq/lldpq/test_alerts.py
   ```
3. Confirm a test message arrives in the configured Slack channel.

Then trip a real alert (cosmetic) by setting a very low threshold in
`notifications.yaml` (e.g. `cpu_temp_warning: 1`) and wait for the next cron
tick. Confirm the alert fires once, then quiets (state file at
`lldpq/alert-states/<device>_cpu_temp.state`).

## 9. Failure-mode validation

These should all degrade gracefully — no 500s, no JS crashes:

| Failure | Expected behavior |
|---------|-------------------|
| Switch unreachable | `assets.ini` last col = `0`, `lldp-problem.html` lists it, alert fires once (Slack if enabled) |
| `devices.yaml` empty | Fabric overview cards show 0s, no JS error |
| UFM not configured | UFM banner shows "not configured", no error spam |
| UFM unreachable | UFM banner shows red "unreachable", other pages still work |
| User pastes `nv show ...` in Command Runner | API rejects with "command not allowed" message |
| User attempts `configure terminal` via Command Runner | Same: rejected |

## 10. Known non-features (do not file bugs)

- "Optical" sidebar item is hidden (Transceiver page covers per-module
  health; deeper BER history view is the Telemetry BER chart instead)
- `device.html` "Capture" and "cl-support" tabs are placeholders explaining
  they are not available in the IB edition
- `provision-api.sh` "Base Config Deploy", "OS Upgrade", and "Deploy
  Generated Config" actions return a structured "disabled in IB edition"
  message — admins push MLNX-OS configs / images via CLI manually
- "Ask AI" requires the operator to configure a provider (Settings cog
  in the AI page). Until then the chat returns a clear "AI provider not
  configured" error. Pick Ollama (local), OpenAI, Claude, or Gemini.

## 11. Demo mode (optional)

If you just want to **showcase the UI without any real switches**:

```bash
docker run -d --name lldpq-ib --network host --privileged \
  -e LLDPQ_DEMO=true \
  lldpq-ib:latest
```

The container will boot pre-populated with a 4-spine + 8-leaf + 16-HCA
NDR fat-tree, SHARP enabled, some realistic problems (1 critical port,
2 warnings, 1 SM disagreement, 1 mixed-FW transceiver model). Cron is
disabled in demo mode so the fake data stays static. Stop the container
and restart without `-e LLDPQ_DEMO=true` to switch back to live
monitoring.

If any "should-pass" gate above fails on real hardware, capture:

- `docker logs lldpq-ib` (last 200 lines)
- `docker exec lldpq-ib cat /etc/lldpq.conf`
- The raw `monitor-results/ib_*.json` files referenced by the broken page
- `curl -i http://<host>/<failing-page>` and the browser-console error

…and file an issue with these artifacts.
