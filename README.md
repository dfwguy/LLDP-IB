# LLDPq InfiniBand Edition

```
██╗     ██╗     ██████╗ ██████╗  ██████╗     ██╗██████╗
██║     ██║     ██╔══██╗██╔══██╗██╔═══██╗    ██║██╔══██╗
██║     ██║     ██║  ██║██████╔╝██║   ██║    ██║██████╔╝
██║     ██║     ██║  ██║██╔═══╝ ██║▄▄ ██║    ██║██╔══██╗
██████╗ ██████╗ ██████╔╝██║     ╚██████╔╝    ██║██████╔╝
╚═════╝ ╚═════╝ ╚═════╝ ╚═╝      ╚══▀▀═╝     ╚═╝╚═════╝
```

Network monitoring for **NVIDIA InfiniBand fabrics** running MLNX-OS.
Sister project of [LLDPq](https://github.com/aliaydemir/lldpq-src) (Ethernet/Cumulus Linux).

> *LLDPq-IB is an independent open-source project. It does not contain, derive
> from, or incorporate any code from NVIDIA UFM or any other commercial product.*
>
> *This software is provided "as is" without warranty. Test in a lab environment
> before deploying to production.*

## What It Does

- **Subnet Manager (SM) status** -- which switch is Master, fabric size, sweep
- **IB Topology** -- switches, HCAs, links (from UFM REST in UFM/hybrid mode)
- **Link errors** -- per-port LinkDowned, SymbolErrors, PortRcvErrors counters
- **P_Key Report** -- partition (VLAN-equivalent) configuration across fabric
- **Multicast Groups** -- IPoIB/MPI/NCCL group membership tracking
- **QoS / Service Levels** -- SL-to-VL mapping per switch
- **SHARP Aggregation Trees** -- NVIDIA in-network reduction visibility
(auto-detected, shown only if SHARP is enabled)
- **Transceiver Inventory** -- per-port vendor PN/SN, firmware, temperature
(from UFM `resources/ports?cable_info=true`)
- **Hardware Health** -- power, fan, temperature per switch (enable-mode SSH)
- **Fabric Events** -- UFM events/alerts as a filterable fabric log
- **GUID / LID Search** -- fabric-wide search by GUID or LID
- **IB Tracepath** -- path between two HCAs (topology BFS; live `ibtracert` where available)
- **Provision (DHCP + MLNX-OS ZTP)** -- zero-touch provisioning for new switches

## Status

**v0.6.0 — UFM-backed hybrid mode, validated against live MLNX-OS NDR
switches + UFM 6.24.**

### How it collects data (important)

MLNX-OS 3.12 admin accounts are **CLI-only** and the `ib` keyword is the
`ibdiagnet` wrapper (not a generic ibutils prefix), so per-switch `ib sminfo` /
`ib ibnetdiscover` style queries do not work. LLDPq-IB therefore runs in a
**UFM-backed hybrid** model:

- **Fabric-wide data** (topology, Subnet Manager, links, P_Keys, transceivers,
SHARP) comes from the **UFM REST API** (`ufm-adapter.py`, every 10 min).
- **Switch-local data** (hardware power/fan/temp, running-config, logs) comes
from **interactive enable-mode SSH** to each switch (`ib-hw-collect.sh`,
`get-configs.sh`).

Set `UFM_URL` + `UFM_USERNAME` + `UFM_PASSWORD` and the container auto-selects
hybrid mode. `LLDPQ_DATA_SOURCE` (`ufm` | `hybrid` | `ssh`) overrides it.

What works:

- SM Status, Link Errors, P_Key, Topology, Search, Tracepath, **Transceiver**,
**Hardware**, **UFM Integration**, **Diagnostics (ibdiagnet)**, and **Logs
(Fabric Events)** — all driven by live UFM + switch data.
- Device Details: Overview, Ports, **Optical** (transceiver inventory),
**Subnet Manager** (fabric SM status), **Logs** (live `show log matching`),
Config, Command Runner.
- IB Wiring validation (design `topology.dot` vs live topology) with
click-to-filter summary cards and CSV export of problem rows.
- Provision / Discover / DHCP / ZTP for MLNX-OS; SSH key push uses **RSA**
(required by MLNX-OS 3.12).
- Fabric Diagnostic: on-demand `ibdiagnet` with parse-then-discard retention;
optional opt-in scheduling (`IBDIAGNET_SCHEDULE`).
- Optional Ask AI (`ai.html`) — IB-context prompts; pick a provider in Settings.
- IB-focused alert engine (`check_alerts.py`).
- **Demo dataset** (`LLDPQ_DEMO=true`): a baked 4-spine + 8-leaf + 16-HCA fake
NDR fat-tree so the UI is full with no real fabric. See "Demo mode" below.

Honest limitations on UFM 6.x REST (pages show a clear message, not an error):

- **Historical telemetry / BER trend** is not exposed over UFM REST on tested
6.x deployments — the Telemetry "BER History" panel says so and points to the
Link Errors page (current counters, collected every 10 min).
- **Multicast** and **QoS / SL2VL** have no UFM REST resource — those pages say
so and point to **Diagnostics → ibdiagnet** for on-demand data.
- Device.html `Capture` / `cl-support` tabs are placeholders (MLNX-OS exposes
those only via `_shell`, which is not whitelisted in `ib-api.sh`).

See [.cursor/ROADMAP.md](./.cursor/ROADMAP.md) for the full plan and
[.cursor/HANDOFF.md](./.cursor/HANDOFF.md) for the current open work list.

## Demo mode

Launch with `LLDPQ_DEMO=true` to ship a fully populated showcase fabric
out of the box -- 4 NDR spines, 8 NDR leaves, 16 ConnectX-7 HCAs in a
classic 2-tier fat-tree. SHARP is enabled. The dataset includes some
realistic problems (1 critical port, 2 warning ports, 1 SM
disagreement, 1 mixed-firmware transceiver model) so every analysis
page shows real content rather than empty tables.

```bash
sudo docker run -d --name lldpq-ib \
  --network host --privileged \
  -e LLDPQ_DEMO=true \
  lldpq-ib:latest
```

In demo mode:

- `lldpq/devices.yaml` is replaced with a 28-entry fake inventory
(`username: nvidia`, fake ssh password `Nvidia@123` -- never used,
monitoring runs via SSH keys only).
- `monitor-results/ib_*.json` are baked in with the demo dataset.
- The cron pipeline is **disabled** so the fake data stays static. Stop
using `-e LLDPQ_DEMO=true` and restart the container to switch back
to live monitoring.

To regenerate the dataset (e.g. tweak counts), edit
`tests/generate_demo_data.py` and rebuild the image.

## Quick Start (Docker only)

LLDPq-IB ships as a pre-built Docker image. Download, load, run:

```bash
# 1. Download the latest image
wget https://aliaydemir.com/lldpq-ib.tar.gz

# 2. Load into Docker
sudo docker load < lldpq-ib.tar.gz

# 3. Run
sudo docker run -d --name lldpq-ib \
  --network host --privileged \
  lldpq-ib:latest
```

Then open `http://<host-ip>` in your browser. Default credentials:

- `admin` / `admin` -- full access
- `operator` / `operator` -- read-only

**Change these passwords on first login.**

### Persistent storage (recommended for production)

The simple command above stores everything inside the container. If you
remove the container, your `devices.yaml`, collected data, and the SSH
key that LLDPq-IB pushed to your switches all disappear with it.

For a long-lived deployment, mount three named volumes so this state
survives upgrades:

```bash
sudo docker run -d --name lldpq-ib \
  --network host --privileged \
  -v lldpq-ib-data:/home/lldpq/lldpq/monitor-results \
  -v lldpq-ib-config:/home/lldpq/lldpq \
  -v lldpq-ib-ssh:/home/lldpq/.ssh \
  lldpq-ib:latest
```


| Volume            | What it holds                                               |
| ----------------- | ----------------------------------------------------------- |
| `lldpq-ib-data`   | All collected IB JSON (every 10-minute cron pass) + history |
| `lldpq-ib-config` | `devices.yaml`, `topology.dot`, alert states, command files |
| `lldpq-ib-ssh`    | The SSH key the container uses to reach your switches       |


With the volumes in place, upgrading to a newer release is just:

```bash
sudo docker stop lldpq-ib && sudo docker rm lldpq-ib
wget -O lldpq-ib.tar.gz https://aliaydemir.com/lldpq-ib.tar.gz
sudo docker load < lldpq-ib.tar.gz
# re-run with the same -v flags
```

### Demo run (no real switches needed)

To see the UI populated with a fake 4-spine + 8-leaf + 16-HCA fabric,
add `-e LLDPQ_DEMO=true`:

```bash
sudo docker run -d --name lldpq-ib \
  --network host --privileged \
  -e LLDPQ_DEMO=true \
  lldpq-ib:latest
```

### Running on a custom port

Port 80 is the default. To use a different port (e.g. when port 80 is
busy on the host), set `LLDPQ_PORT`:

```bash
sudo docker run -d --name lldpq-ib \
  --network host --privileged \
  -e LLDPQ_PORT=8090 \
  -e LLDPQ_DEMO=true \
  lldpq-ib:latest
```

Then open `http://<host-ip>:8090/`. (Add the `-v` volume flags from
the "Persistent storage" section above for production deployments.)

> With `--network host` the container shares the host's network stack,
> so Docker's standard `-p 8090:80` mapping does NOT apply -- `LLDPQ_PORT`
> reconfigures the in-container nginx instead.

Image is amd64-only.

## Configuration

### devices.yaml

Define your InfiniBand switches:

```yaml
defaults:
  username: admin

devices:
  10.10.100.10: ib-spine-01 @spine
  10.10.100.11: ib-spine-02 @spine
  10.10.100.20: ib-leaf-01 @leaf
  10.10.100.21: ib-leaf-02 @leaf
```

Roles: `switch`, `spine`, `leaf`, `core`, `border` (any tag you like).

### SSH Access

LLDPq-IB connects to switches as `admin` (MLNX-OS default) using an **RSA** key.
MLNX-OS 3.12 rejects ed25519 keys, so use RSA. The easiest path is the **Setup**
page ("Push SSH key to all switches"), which generates the key and installs it
for you. Manual flow:

```bash
# On the LLDPq-IB host (RSA, not ed25519):
sudo docker exec lldpq-ib ssh-keygen -t rsa -b 4096 -N '' -f /home/lldpq/.ssh/id_rsa

# Copy the public key (output of below) to each MLNX-OS switch:
sudo docker exec lldpq-ib cat /home/lldpq/.ssh/id_rsa.pub

# On MLNX-OS (enable / configure terminal):
switch (config) # ssh client user admin authorized-key sshv2 "ssh-rsa AAAA..."
switch (config) # write memory
```

> MLNX-OS admin is **CLI-only**: LLDPq-IB never runs `ssh host "command"` (exec
> mode is rejected). It opens an interactive enable-mode session and pipes
> commands in.

### UFM Integration (primary data source for MLNX-OS NDR)

NVIDIA's Unified Fabric Manager (UFM) is the **authoritative fabric data source**
for MLNX-OS NDR fabrics (where switches are CLI-only). Point LLDPq-IB at UFM and
it runs in **hybrid mode**: UFM REST for fabric-wide data + switch SSH for
hardware/logs/config.

Recommended run (matches a real UFM-appliance deployment):

```bash
sudo docker run -d --name lldpq-ib \
  --network host --privileged \
  -e LLDPQ_PORT=8090 \
  -e UFM_URL=https://10.230.237.6 \
  -e UFM_USERNAME=admin \
  -e UFM_PASSWORD='123456' \
  -v /root/lldpq-pre/ssh:/home/lldpq/.ssh-mount:ro \
  -v /root/lldpq-pre/devices.yaml:/home/lldpq/lldpq/devices.yaml \
  -v lldpq-ib-data:/home/lldpq/lldpq/monitor-results \
  lldpq-ib:latest
```

- `UFM_URL` -- base URL of the UFM GUI/REST host (e.g. `https://10.230.237.6`).
  Do **not** append `/ufmRest`; the adapter adds the right prefix.
- `UFM_USERNAME` + `UFM_PASSWORD` -- UFM credentials (or pass a pre-built
  `UFM_TOKEN` = base64 `user:password`). Can also be set later from the **UFM**
  page in the UI.
- `UFM_VERIFY_TLS` -- `true` to verify the UFM cert, `false` (default) for
  self-signed.
- `LLDPQ_DATA_SOURCE` -- `hybrid` (auto when `UFM_URL` is set), `ufm` (no switch
  SSH), or `ssh` (legacy).

What UFM provides (UFM sidebar + Analysis pages): connection status + version,
fabric **events/alerts** (also the **Logs** page), **systems/links** topology
cross-check, per-port **transceiver/cable** inventory, P_Keys, and SHARP.

What UFM 6.x REST does **not** expose (pages say so honestly): historical
telemetry / BER trend, multicast groups, and QoS/SL2VL. Use **Diagnostics →
ibdiagnet** for on-demand multicast/QoS/SL data; current BER/error counters are
on the **Link Errors** page.

> The `monitor-results` volume just caches the last generated data; it is **not**
> required and is **not** a source of stale UI — `ufm-adapter.py` overwrites it
> every 10 minutes. Removing it only means the pages are empty for one cron cycle
> after a fresh start.

## Documentation

- [.cursor/STORY.md](./.cursor/STORY.md) -- why this project exists
- [.cursor/ARCHITECTURE.md](./.cursor/ARCHITECTURE.md) -- key design decisions
- [.cursor/ROADMAP.md](./.cursor/ROADMAP.md) -- phases and milestones
- [docs/HW-TEST-CHECKLIST.md](./docs/HW-TEST-CHECKLIST.md) -- first-deployment
playbook against real MLNX-OS IB switches

## Differences from LLDPq (Ethernet)


| Aspect             | LLDPq (Ethernet)         | LLDPq-IB               |
| ------------------ | ------------------------ | ---------------------- |
| Switch OS          | Cumulus Linux (NVUE/FRR) | MLNX-OS                |
| L2 address         | MAC                      | GUID                   |
| L3 address         | IP                       | LID                    |
| Segmentation       | VLAN                     | P_Key                  |
| Routing protocol   | BGP, OSPF                | Subnet Manager         |
| Topology discovery | LLDP                     | `ibnetdiscover`        |
| Link flap counter  | `carrier_changes`        | `LinkDownedCounter`    |
| Config management  | Ansible (optional)       | None (monitoring-only) |
| Deployment         | install.sh OR Docker     | **Docker-only**        |


## Out of Scope

- **Configuration management** -- LLDPq-IB does NOT push config to switches.
Use UFM or your IaC tool of choice for that.
- **HCA (host) monitoring** -- only switch-side. Use `mlnx-tools` on hosts.
- **Multi-subnet fabrics** -- single `infiniband-default` subnet assumed.

## For Developers

If you want to fork, modify, or rebuild the image yourself:

```bash
git clone https://github.com/aliaydemir/lldpq-ib-src.git
cd lldpq-ib-src
./docker/docker-build.sh          # produces ~/lldpq-ib.tar.gz (amd64-only)
```

Optional: push to your own registry instead of distributing the tarball:

```bash
LLDPQ_REGISTRY=registry.example.com/lldpq ./docker/docker-push.sh
```

End users then pull from your registry:

```bash
docker pull registry.example.com/lldpq/lldpq-ib:latest
```

## License

MIT License -- see [LICENSE](LICENSE).  


```bash

rm -rf lldpq-ib.tar.gz
sudo docker stop lldpq-ib && sudo docker rm lldpq-ib
sudo docker rmi lldpq-ib:latest
wget -O lldpq-ib.tar.gz https://aliaydemir.com/lldpq-ib.tar.gz
sudo docker load < lldpq-ib.tar.gz
sudo docker run -d --name lldpq-ib \
  --network host --privileged \
  -e LLDPQ_PORT=8090 \
  -e LLDPQ_DEMO=true \
  lldpq-ib:latest

```

```bash

rm -rf lldpq-ib.tar.gz
sudo docker stop lldpq-ib && sudo docker rm lldpq-ib
sudo docker rmi lldpq-ib:latest
wget -O lldpq-ib.tar.gz https://aliaydemir.com/lldpq-ib.tar.gz
sudo docker load < lldpq-ib.tar.gz
sudo docker run -d --name lldpq-ib \
  --network host --privileged \
  -e LLDPQ_PORT=8090 \
  lldpq-ib:latest

```

sudo docker exec -it -u lldpq lldpq-ib bash

