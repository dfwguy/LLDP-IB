# LLDPq-IB Command Inventory

This file lists the commands and API calls LLDPq-IB sends to:

- NVIDIA MLNX-OS InfiniBand switches
- NVIDIA UFM REST API

It is meant as an operator/security review reference. LLDPq-IB is monitoring and
diagnostic focused. Configuration-management features are intentionally out of
scope.

## Important Rules

- LLDPq-IB does **not** prepend `sudo` to MLNX-OS switch commands.
- MLNX-OS native commands are sent to the switch CLI as `show ...`.
- ibutils are run through the MLNX-OS CLI `ib ...` prefix.
- Heavy commands such as `ib ibroute` are **manual only**, never cron.
- `ibdiagnet` is **on-demand by default**; it can be opt-in scheduled
  (`IBDIAGNET_SCHEDULE`) but always parses-then-discards its 2-3 GB output with a
  retention cap (see [Fabric Diagnostic](#fabric-diagnostic-ibdiagnet)).
- SSH commands shown below run as the username from `devices.yaml` (normally
  `admin`).

## Periodic Switch Collection

Source: `lldpq/ib-monitor.sh`

Schedule: every 10 minutes via `/usr/local/bin/lldpq`, unless
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
show log files | head -20
show log continuous | grep -E "ERR|WARN|FAIL|DOWN" | tail -50
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

Normally:

```text
ssh client user admin authorized-key sshv2 "ssh-ed25519 ..."
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

### Preset commands in Device Details

System and hardware:

```text
show version
show inventory
show power
show fan
show temperature
show resources
show clock
```

IB interfaces:

```text
show interfaces ib status
show interfaces ib link-diagnostics
show interfaces ib transceiver
show interfaces ib transceiver diagnostics
show interfaces ib <port>
show interfaces ib <port> transceiver
show interfaces ib <port> transceiver diagnostics
show interfaces ib <port> counters
```

Subnet Manager and topology:

```text
ib sminfo
show ib smnodes
ib ibswitches
ib ibhosts
ib ibnetdiscover -l
ib iblinkinfo --line
ib ibqueryerrors
```

P_Key, multicast and QoS:

```text
show ib partition
show ib qos-profile
ib saquery -m
```

Performance and SHARP:

```text
ib perfquery -a
ib ibqueryerrors --details
show ib sharp aggregation-nodes
```

Management shell reads:

```text
ip link show
ip addr show
uptime
free -h
df -h
```

Logs:

```text
show log files
show log continuous
show log matching ERR
show log matching WARN
show log matching <ERR|WARN|INFO> | tail -n 200
```

Subnet Manager tab:

```text
ib sminfo
```

Optical/L1 detail:

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

All requests use:

```text
Authorization: Basic <UFM_TOKEN>
```

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
GET <UFM_URL>/ufmRest/app/events?active=true
```

Purpose:

- active UFM alerts
- severity summary

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

### BER / telemetry history

```text
GET <UFM_URL>/ufmRestV3/telemetry/historical/ports?<query>
```

The UI passes query parameters after `action=ber-history&`, for example:

```text
counter=ber_total_phy
duration=<seconds>
system_guid=<guid>
```

Purpose:

- BER history chart
- UFM telemetry trends

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
local_link_count
ufm_link_count
```

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
| `lldpq/ib-monitor.sh` | IB switches | periodic monitoring collection |
| `lldpq/ib-assets.sh` | IB switches | quick identity/reachability inventory |
| `lldpq/get-configs.sh` | IB switches | running-config backup |
| `lldpq/send-key.sh` | IB switches | initial SSH public key installation |
| `html/mlnxos-ztp.sh` | local switch during ZTP | hostname/password/key/config bootstrap |
| `html/ib-api.sh` | IB switches | safe command runner, live `ibtracert` |
| `html/diagnostics.html` | IB switches through `ib-api.sh` | manual diagnostics |
| `html/diag-api.sh` | launches `run-ibdiagnet.sh` | fabric diagnostic run/status/history API |
| `lldpq/run-ibdiagnet.sh` | UFM appliance or IB switch | full-fabric `ibdiagnet` (parse-then-discard) |
| `html/ufm-api.sh` | UFM REST API | UFM version, alerts, systems, links, BER history |
| `html/setup-api.sh` | local trigger files | first collection queue |

