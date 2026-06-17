# LLDPq-IB Command Inventory

This file lists the commands and API calls LLDPq-IB sends to:

- NVIDIA MLNX-OS InfiniBand switches
- NVIDIA UFM REST API

It is meant as an operator/security review reference. LLDPq-IB is monitoring and
diagnostic focused. Configuration-management features are intentionally out of
scope.

## Important Rules

- LLDPq-IB does **not** prepend `sudo` to MLNX-OS switch commands.
- MLNX-OS admin accounts are **CLI-only**: `ssh host "command"` (exec mode) is
  rejected ("UNIX shell commands cannot be executed"). LLDPq-IB drives an
  interactive enable-mode session (`ssh -tt`) and pipes the commands in.
- MLNX-OS does **not** support shell pipes in the CLI (`show ... | tail` returns
  "Command not filterable"). Native filters such as `show log matching <regex>`
  are used instead.
- On MLNX-OS 3.12 the `ib` keyword is the **`ibdiagnet` wrapper**, NOT a generic
  prefix for individual ibutils. `ib sminfo`, `ib saquery`, `ib ibnetdiscover`,
  `ib iblinkinfo`, `ib ibqueryerrors` do **not** work as standalone queries.
  Fabric-wide data (topology, SM, links, P_Keys, transceivers, SHARP) therefore
  comes from the **UFM REST API**; switch-local data (hardware, logs,
  running-config) comes from `show ...`.
- SSH key auth to MLNX-OS requires an **RSA** key (`ssh client user admin
  authorized-key sshv2 "ssh-rsa ..."`); ed25519 is rejected by 3.12.
- `ibdiagnet` is **on-demand by default**; it can be opt-in scheduled
  (`IBDIAGNET_SCHEDULE`) but always parses-then-discards its 2-3 GB output with a
  retention cap (see [Fabric Diagnostic](#fabric-diagnostic-ibdiagnet)).
- SSH commands shown below run as the username from `devices.yaml` (normally
  `admin`).

## Data Source Modes

`LLDPQ_DATA_SOURCE` (env, persisted to `/etc/lldpq.conf`) selects how data is
collected. When `UFM_URL` is set the entrypoint selects **hybrid** automatically.

| Mode | Fabric data (topology/SM/links/P_Key/transceiver/SHARP) | Switch-local data (HW/logs/config) |
|---|---|---|
| `ufm` | UFM REST (`ufm-adapter.py`) | none |
| `hybrid` (recommended, MLNX-OS NDR + UFM) | UFM REST (`ufm-adapter.py`) | switch SSH (`ib-hw-collect.sh`, `get-configs.sh`) |
| `ssh` (legacy) | per-switch SSH (`ib-monitor.sh`) — only on platforms where standalone ibutils run from the CLI; **not** MLNX-OS 3.12 | switch SSH |

## UFM-Backed Hybrid Collection (default for MLNX-OS + UFM)

Cron (`/etc/cron.d/lldpq`, written by `docker/docker-entrypoint.sh`):

```text
*/10 * * * *  python3 ufm-adapter.py            # fabric data from UFM REST
*/15 * * * *  bash ib-hw-collect.sh             # switch hardware (enable-mode SSH)
              && python3 generate_hardware_html.py
              && cp monitor-results/hardware-analysis.html /var/www/html/monitor-results/
*  * * * *    lldpq-trigger                      # web UI Refresh buttons
0 */6 * * *   bash get-configs.sh                # running-config backup
```

`ufm-adapter.py` writes `monitor-results/ib_topology.json`, `ib_sm_status.json`,
`ib_link_errors.json`, `ib_pkey.json`, `ib_sharp_status.json`,
`transceiver_inventory.json`, and `assets.ini`. `ib-hw-collect.sh` writes
`hardware-data/<host>_hardware.txt` and `switch_identity.json`. See
[UFM REST API Calls](#ufm-rest-api-calls) and
[Switch Hardware Collection](#switch-hardware-collection-hybrid-mode).

## Switch Hardware Collection (hybrid mode)

Source: `lldpq/ib-hw-collect.sh` (interactive enable-mode SSH, RSA key auth).

```text
show version
show inventory
show temperature
show fan
show power
```

Purpose:

- MLNX-OS release, model, chassis serial, uptime -> `switch_identity.json`
- ASIC/board temperature, fan RPM, PSU power -> `hardware-data/<host>_hardware.txt`
- rendered into `hardware-analysis.html` by `generate_hardware_html.py`

## Periodic Switch Collection (legacy `ssh` mode only)

Source: `lldpq/ib-monitor.sh`

> **Legacy.** This single-session SSH collection only runs in `ssh` mode and is
> **disabled in `ufm`/`hybrid` mode** (it exits early). The fabric-wide `ib ...`
> commands below assume standalone ibutils run from the CLI, which is **not** the
> case on MLNX-OS 3.12 (where `ib` = ibdiagnet). On MLNX-OS + UFM these data sets
> come from the UFM REST API instead — see
> [UFM REST API Calls](#ufm-rest-api-calls). The section is kept for non-MLNX-OS
> platforms and historical reference.

Schedule (ssh mode): every 10 minutes via `/usr/local/bin/lldpq`, unless
`LLDPQ_DEMO=true`.

Each switch is polled in one SSH session. Output is separated by marker
sections and parsed locally.

### Identity

```text
show version
show inventory
```

Purpose:

- MLNX-OS release
- product name
- chassis serial
- model / inventory details

### Interface Status

```text
show interfaces ib status
```

Purpose:

- IB port list
- port state
- speed / link state

### Link Diagnostics

```text
show interfaces ib link-diagnostics
```

Purpose:

- physical layer diagnostic codes
- cable/link failure hints

### Interface Counters

```text
show interfaces ib
```

Purpose:

- per-port counters
- LinkDowned / SymbolError / receive/transmit error visibility where present

### Transceiver Inventory

```text
show interfaces ib transceiver
```

Purpose:

- transceiver vendor
- part number
- serial number
- firmware revision where MLNX-OS exposes it

### Transceiver / Cable Diagnostics

```text
show interfaces ib transceiver diagnostics
```

Purpose:

- RX/TX optical power
- temperature
- DOM / cable diagnostics

### Fabric Topology

```text
ib ibnetdiscover -p
```

Purpose:

- switch GUIDs
- HCA GUIDs
- LIDs
- physical links
- speeds

### Link Info

```text
ib iblinkinfo --line
```

Purpose:

- per-link state
- link speed
- peer relationships

### Subnet Manager

```text
ib sminfo
```

Purpose:

- Master SM
- Standby SMs
- SM state
- SM priority
- SM disagreement detection

### Performance / Error Counters

```text
ib ibqueryerrors --details
```

Fallback:

```text
ib perfquery -a
```

Purpose:

- LinkDownedCounter
- SymbolErrorCounter
- LinkErrorRecoveryCounter
- PortRcvErrors
- PortXmitDiscards
- PortXmitWait
- VL15Dropped

### P_Key Partitions

```text
show ib partition
```

Purpose:

- P_Key inventory
- partition names
- member GUIDs
- membership type
- cross-device consistency
- expected policy comparison through `expected_pkeys.yaml`

### Multicast Groups

```text
ib saquery -m
```

Purpose:

- MGID
- MLID
- P_Key distribution
- IPoIB / NCCL / MPI multicast visibility

### QoS Profiles

```text
show ib qos-profile
```

Purpose:

- SL to VL mapping
- QoS profile consistency

### SHARP

```text
show ib sharp aggregation-nodes
```

Fallback text if unavailable:

```text
SHARP_NOT_AVAILABLE
```

Purpose:

- SHARP enabled/disabled detection
- aggregation nodes
- aggregation trees

### Hardware Sensors

```text
show power
show fan
show temperature
```

Purpose:

- PSU status
- fan state / fan RPM
- CPU / ASIC / board temperature

### Logs

```text
show log matching CRIT
show log matching ERR
show log matching WARN
```

Purpose:

- recent warning/error/failure hints
- input for `log-analysis.html`

## Quick Asset Probe

Source: `lldpq/ib-assets.sh`

Used by:

- cron wrapper
- setup/provision flows
- Assets page

Commands:

```text
show version
show inventory
```

Purpose:

- fast reachability and identity check
- `assets.ini` generation

## Running Config Backup

Source: `lldpq/get-configs.sh`

Schedule: every 12 hours via cron, unless demo mode is active.

Command:

```text
show running-config
```

Purpose:

- saves MLNX-OS running config under `/var/www/html/configs/`
- displayed by `dev-conf.html`

Related manual command exposed from device pages:

```text
show running-config
show running-config expanded
show running-config diff
```

## SSH Key Distribution

Sources:

- `lldpq/send-key.sh`
- `html/mlnxos-ztp.sh`
- `html/provision.html`
- `html/setup.html`

Command pushed to MLNX-OS:

```text
ssh client user <user> authorized-key sshv2 "<public-key>"
```

Normally (MLNX-OS 3.12 requires an **RSA** key; ed25519 is rejected):

```text
ssh client user admin authorized-key sshv2 "ssh-rsa AAAA..."
```

Interactive CLI flow used by `send-key.sh`:

```text
enable
configure terminal
ssh client user <user> authorized-key sshv2 "<public-key>"
write memory
exit
exit
```

Purpose:

- install LLDPq-IB collector SSH key on each switch

## MLNX-OS ZTP

Source: `html/mlnxos-ztp.sh`

Served by nginx:

```text
GET /mlnxos-ztp.sh
```

The script is fetched by the switch during ZTP through DHCP option 239.
The DHCP option name is historically `cumulus-provision-url`, but LLDPq-IB
serves an MLNX-OS script.

### Commands executed by the ZTP script

Reachability:

```text
ping -c2 <LLDPQ_IB_HOST>
```

Serial lookup:

```text
show inventory
```

Configuration sequence sent to MLNX-OS CLI:

```text
enable
configure terminal
username admin password <password>
ssh client user admin authorized-key sshv2 "<public-key>"
hostname <resolved-hostname>
configuration file install /tmp/lldpq-ib-startup.cfg
write memory
exit
exit
```

Optional file fetch from LLDPq-IB host:

```text
curl -sf http://<LLDPQ_IB_HOST>/serial-mapping.txt
curl -sf --head http://<LLDPQ_IB_HOST>/generated_config_folder/<hostname>.cfg
curl -sf http://<LLDPQ_IB_HOST>/generated_config_folder/<hostname>.cfg -o /tmp/lldpq-ib-startup.cfg
```

Purpose:

- set admin password if configured
- install SSH key
- set hostname
- optionally apply per-switch MLNX-OS config snippet
- persist changes

## Device Details / Command Runner

Source: `html/device.html` through `html/ib-api.sh?action=run-device-command`

The API has a whitelist. Commands outside the whitelist are rejected.

### Allowed top-level command patterns

```text
show ...
ib ...
ip link ...
ip addr ...
ip route ...
ip neigh ...
uptime
free ...
df ...
cat /var/log/...
tail /var/log/...
journalctl ...
dmesg ...
```

### Allowed pipe filters

```text
grep
head
tail
wc
awk
sed
sort
uniq
cut
tr
column
```

### Forbidden examples

These are rejected from Command Runner:

```text
reboot
shutdown
write memory
write terminal
copy
delete
configure terminal
ib sm stop
ib sm start
ib sm disable
ib sm enable
mlxfwmanager
flint
```

### Preset commands in Device Details + Command Runner

These presets back two surfaces and are kept in sync:

- `html/device.html` "Command Runner" tab (single device, in the device context)
- `html/cmd-runner.html` "Command Runner" page (sidebar: Devices > Commands) — runs on a
  single device, a role group, or **all switches** (client-side parallel fan-out)

**All commands below were verified to return real output on MLNX-OS 3.12 switch CLI
(interactive enable mode).** Two classes were intentionally removed because the CLI
returns usage/help, not data:

- `ib <util>` (`ib ibhosts` / `ib ibnetdiscover` / `ib iblinkinfo` / `ib ibqueryerrors` /
  `ib saquery` / `ib perfquery`) — on MLNX-OS `ib` is an **ibdiagnet wrapper**, so these
  print ibdiagnet usage. Fabric-wide IB data comes from UFM / the ibdiagnet Diagnostics page.
- Linux shell reads (`ip link show`, `ip addr show`, `uptime`, `free -h`, `df -h`) and
  `show ib qos-profile` / `show ib sharp aggregation-nodes` — the CLI returns
  `% Unrecognized command` (shell reads need `_shell`, which is not exposed).

System and hardware:

```text
show version
show inventory
show asic-version
show module
show images
show power
show fan
show temperature
show resources
show health-report
show clock
```

IB interfaces:

```text
show interfaces ib status
show interfaces ib link-diagnostics
show interfaces ib transceiver
show interfaces ib transceiver diagnostics
show interfaces ib <port>                            # device.html port input only
show interfaces ib <port> transceiver
show interfaces ib <port> transceiver diagnostics
show interfaces ib <port> counters
```

Subnet Manager & P_Key (MLNX-OS native; the `ib <util>` forms are NOT used):

```text
show ib sm
show ib smnodes
show ib partition
```

> Fabric-wide SM/topology/links/P_Key data is read from the UFM REST API
> (`ufm-adapter.py`), not from per-switch `ib ...` commands.

Management & network:

```text
show ip interface
show ip route
show ntp
show snmp
show ssh server
```

Configuration:

```text
show running-config
show images
```

Logs (no shell pipes on MLNX-OS — native regex match only):

```text
show log files
show log continuous
show log matching ERR
show log matching WARN
show log matching INFO
```

Subnet Manager tab:

- Reads `monitor-results/ib_sm_status.json` (fabric SM from UFM); it does **not**
  run a per-switch command (the IB SM is fabric-wide, on the UFM appliance).

Optical tab:

- Reads `monitor-results/transceiver_inventory.json` (per-switch transceiver
  inventory, sourced from UFM `resources/ports?cable_info=true`). Clicking a row
  runs live L1 detail:

```text
show interfaces ib <port> transceiver diagnostics
```

## Tracepath

Source:

- `html/tracepath.html`
- `html/ib-api.sh?action=ibtracert`

Live trace command:

```text
ib ibtracert -G <src_guid> <dst_guid>
```

Notes:

- Runs from the first reachable switch in `assets.ini`.
- If live trace is unavailable, UI falls back to topology BFS from
  `ib_topology.json`.

## Manual Diagnostics

Source: `html/diagnostics.html`

These commands are manual-only. They are never scheduled in cron.

Safe presets:

```text
ib sminfo
ib iblinkinfo --line
ib ibqueryerrors --details
ib saquery -m
ib ibnetdiscover -p
```

Heavy preset:

```text
ib ibroute
```

Notes:

- `ib ibroute` can generate large output.
- Use it only for manual TAC/debug workflows.

## Fabric Diagnostic (ibdiagnet)

Sources:

- `html/diagnostics.html` (the builder + result view)
- `html/diag-api.sh` (run/status/last/runs/targets API; admin only)
- `lldpq/run-ibdiagnet.sh` (SSH + run + collect + discard + retention)
- `lldpq/process_ibdiagnet.py` (parse output -> compact JSON)

This is the rich, fabric-wide health source. It is **on-demand by default**; it is
only scheduled when the admin explicitly sets `IBDIAGNET_SCHEDULE` (see below).

The command sent to the target (built from the UI checkboxes; the reference
"Full run preset" reproduces the command shared by the IB SA team):

```text
ibdiagnet --routing --ft --get_phy_info --rail_validation --sc \
  --extended_speeds all --pm_per_lane -P all=1 --get_cable_info \
  --mads_timeout 2000 --mads_retries 3 \
  --enable_output log,lst,sm,pm,iblinkinfo,fdbs,ar,far,slvl,rnc2 \
  -o <managed-temp-dir>
```

On the UFM appliance the binary path is `/opt/ufm/opensm/bin/ibdiagnet`.

Important about the output path and cleanup:

- `-o` is **always managed by LLDPq-IB** (a per-run temp dir on the target). A
  caller-supplied `-o` is rejected. Flags are built from a fixed whitelist; raw
  flag strings are never passed through.
- ibdiagnet produces 2-3 GB of raw files. LLDPq-IB pulls back only the small
  files needed to parse (excludes `ibdiagnet2.db_csv`, `ibdiagnet2.pm`, `*.fdbs`,
  `*.net_dump`), extracts the signal into `monitor-results/ib_fabric_diag.json`,
  and then **deletes the raw output on the target**:

```text
# remote (run, collect-small, optional full archive, then delete):
mkdir -p <managed-temp-dir> && ibdiagnet <flags> -o <managed-temp-dir>
tar czf - -C <managed-temp-dir> --exclude=ibdiagnet2.db_csv --exclude=ibdiagnet2.pm --exclude='*.fdbs' --exclude='*.net_dump' .
tar czf - -C <managed-temp-dir> .            # only when IBDIAGNET_KEEP_RAW > 0
rm -rf <managed-temp-dir>
```

- Retention keeps the newest `IBDIAGNET_KEEP_RAW` archives (default 1) and the
  newest `IBDIAGNET_KEEP_RUNS` parsed summaries (default 20); older ones are
  pruned automatically so the data volume never grows unbounded.

Output files written under `monitor-results/`:

```text
ib_fabric_diag.json                 # latest parsed summary (UI default view)
ibdiag-runs/index.json              # run history
ibdiag-runs/<run_id>.json           # per-run summary
ibdiag-runs/<run_id>.status         # poll target while running
ibdiag-runs/<run_id>.tar.gz         # retained raw archive (if kept)
```

Optional scheduled run (OFF by default), configured via container env and
persisted to `/etc/lldpq.conf`:

```text
IBDIAGNET_SCHEDULE   # cron expression ("0 */2 * * *") or bare integer N (every N hours)
IBDIAGNET_TARGET     # device hostname or UFM SSH host; required to enable scheduling
IBDIAGNET_USER       # SSH user (default admin; UFM appliance often root)
IBDIAGNET_BIN        # ibdiagnet | /opt/ufm/opensm/bin/ibdiagnet
IBDIAGNET_FLAGS      # override the default scheduled flag set
IBDIAGNET_KEEP_RAW   # retained raw archives (default 1; 0 = leanest, no big transfer)
IBDIAGNET_KEEP_RUNS  # retained parsed summaries (default 20)
UFM_SSH_HOST         # SSH host of the UFM appliance (enables the "ufm" target)
UFM_SSH_USER         # SSH user for the UFM appliance (default root)
```

Mock mode (`LLDPQ_IB_MOCK=1`) parses `tests/fixtures/ibdiagnet/` instead of SSH,
so the demo and offline tests show a populated report with no real fabric.

## Setup / First Collection

Source: `html/setup-api.sh`

The setup page does not send commands to switches directly. It queues collection
by writing trigger files:

```text
/tmp/.assets_web_trigger
/tmp/.monitor_web_trigger
```

Then `lldpq-trigger` runs:

```text
ib-assets.sh
ib-monitor.sh
```

In `LLDPQ_DEMO=true`, collection is refused so fake data stays static.

## Web Triggered Collection

Sources:

- `html/trigger-assets.sh`
- `html/trigger-monitor.sh`
- `html/trigger-lldp.sh`
- `bin/lldpq-trigger`

Trigger files:

```text
/tmp/.assets_web_trigger
/tmp/.monitor_web_trigger
/tmp/.lldp_web_trigger
/tmp/.configs_web_trigger
```

Triggered scripts:

```text
ib-assets.sh
ib-monitor.sh
get-configs.sh
```

## UFM REST API Calls

Source: `html/ufm-api.sh`

All requests use HTTP Basic auth:

```text
Authorization: Basic <UFM_TOKEN>
```

Credentials come from `/etc/lldpq.conf` (or container env):

- `UFM_TOKEN` = base64(`username:password`), OR
- `UFM_USERNAME` + `UFM_PASSWORD` (the UI Configure-UFM form takes these and
  stores them as `UFM_TOKEN`; `ufm-adapter.py` also accepts them directly).

TLS verification:

- default: disabled (`curl --insecure`)
- if `UFM_VERIFY_TLS=true`: TLS verification enabled

Base URL comes from:

```text
UFM_URL
```

Typically:

```text
https://<ufm-host>/ufmRest
```

### UFM status

```text
GET <UFM_URL>/ufmRest/app/ufm_version
```

Purpose:

- determine if UFM is configured/reachable
- read UFM version

### Active events / alerts

```text
GET <UFM_URL>/ufmRest/app/events
```

> UFM 6.x rejects `?active=true` (HTTP 400 "request argument 'active' is not
> allowed"). LLDPq-IB fetches the full event list and normalizes/sorts locally.
> Fields used: `severity`, `object_name` (source), `name` (description),
> `timestamp`, `category`. Powers the **UFM** tab alerts and the **Logs**
> (Fabric Events) page (`ib-logs.html`).

Purpose:

- fabric events / alerts (severity bucketed into critical/warning/info)
- severity summary

### Transceiver / cable inventory

```text
GET <UFM_URL>/ufmRest/resources/ports?cable_info=true&active=true
```

Purpose:

- per-port transceiver part number, serial, FW, identifier, temperature, length
- written to `transceiver_inventory.json` (Transceiver page + Device Optical tab)

### Systems

```text
GET <UFM_URL>/ufmRest/resources/systems
```

Purpose:

- UFM switch/HCA inventory
- topology cross-check

### Links

```text
GET <UFM_URL>/ufmRest/resources/links
```

Purpose:

- UFM link inventory
- local-vs-UFM topology validation

### BER / telemetry history (not available on UFM 6.x REST)

```text
GET <UFM_URL>/ufmRestV3/telemetry/historical/ports?<query>
```

> On UFM 6.x this endpoint (and all `/telemetry/...` REST paths) returns **404**;
> the secondary telemetry exporter (port 9001) is not reachable from the LLDPq-IB
> host in tested deployments. The `ber-history` proxy validates the response and
> returns a clean JSON status (`success:false, available:false`) so the Telemetry
> page shows an honest "not available — see Link Errors" message instead of
> crashing on the 404 HTML. BER/error counters are surfaced on the **Link Errors**
> page (current state, from `ufm-adapter.py` every 10 min) instead.

### Endpoints intentionally NOT used (no UFM REST resource)

UFM 6.x has **no** REST resource for these, so the related pages show an honest
"not collected" state (use **Diagnostics → ibdiagnet** for on-demand data):

```text
/ufmRest/resources/mcast_groups   -> 404   (Multicast page)
/ufmRest/resources/qos            -> 404   (QoS page)
/ufmRest/resources/sl2vl          -> 404   (QoS page)
```

### Topology validation

Uses both:

```text
GET <UFM_URL>/ufmRest/resources/systems
GET <UFM_URL>/ufmRest/resources/links
```

Then compares UFM GUIDs to local `monitor-results/ib_topology.json`.

Output categories:

```text
only_in_local
only_in_ufm
common_count
aggregation_excluded   # SHARP aggregation nodes (in UFM /modules, not /systems) — excluded so they don't look like a discrepancy
local_link_count
ufm_link_count
```

> GUIDs are normalized (strip `0x`, lowercase) on both sides before comparison,
> and SHARP aggregation nodes are excluded from the local set (UFM lists them
> under `/resources/modules`, not `/resources/systems`). Without this, every node
> would appear as a false discrepancy.

## UFM Configuration Writes

Source: `html/ufm-api.sh?action=save-config`

This does not call UFM. It writes local LLDPq-IB settings into:

```text
/etc/lldpq.conf
```

Keys written:

```text
UFM_URL=<url>
UFM_TOKEN=<base64(username:password)>
UFM_VERIFY_TLS=<true|false>
```

## Commands Mentioned But Not Automated

These are documented for operators but are not automatically run by LLDPq-IB:

```text
image fetch <url>
image install <image-name>
show images
reload
```

Purpose:

- manual MLNX-OS image upgrade flow

LLDPq-IB currently does not automate MLNX-OS upgrades.

## Summary by Source File

| Source | Sends to | Purpose |
|---|---|---|
| `lldpq/ufm-adapter.py` | UFM REST API | **fabric data** (topology/SM/links/P_Key/transceiver/SHARP) + `assets.ini` (ufm/hybrid mode) |
| `lldpq/ib-hw-collect.sh` | IB switches (enable-mode SSH) | switch hardware (version/inventory/temperature/fan/power) + `switch_identity.json` |
| `lldpq/generate_hardware_html.py` | local (reads hardware-data) | renders `hardware-analysis.html` |
| `lldpq/get-configs.sh` | IB switches | running-config backup |
| `lldpq/send-key.sh` | IB switches | initial SSH public key installation (RSA) |
| `html/mlnxos-ztp.sh` | local switch during ZTP | hostname/password/key/config bootstrap |
| `html/ib-api.sh` | IB switches | safe command runner, device data, live L1 detail |
| `html/diagnostics.html` | IB switches through `ib-api.sh` | manual diagnostics |
| `html/diag-api.sh` | launches `run-ibdiagnet.sh` | fabric diagnostic run/status/history API |
| `lldpq/run-ibdiagnet.sh` | UFM appliance or IB switch | full-fabric `ibdiagnet` (parse-then-discard) |
| `html/ufm-api.sh` | UFM REST API | UFM version, events, systems, links, cable_info, topology validation |
| `html/ib-logs.html` | UFM REST API (via `ufm-api.sh`) | fabric events / log view |
| `html/setup-api.sh` | local trigger files / `send-key.sh` | first collection queue, SSH key push |
| `lldpq/ib-monitor.sh` | IB switches | **legacy** periodic collection (`ssh` mode only; disabled on MLNX-OS) |
| `lldpq/ib-assets.sh` | IB switches | quick identity/reachability inventory (legacy/ssh) |

