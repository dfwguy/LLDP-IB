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
- **IB Topology** -- discover switches, HCAs, links via `ibnetdiscover`
- **Link errors** -- per-port LinkDowned, SymbolErrors, PortRcvErrors counters
- **P_Key Report** -- partition (VLAN-equivalent) configuration across fabric
- **Multicast Groups** -- IPoIB/MPI/NCCL group membership tracking
- **QoS / Service Levels** -- SL-to-VL mapping per switch
- **SHARP Aggregation Trees** -- NVIDIA in-network reduction visibility
(auto-detected, shown only if SHARP is enabled)
- **Transceiver Inventory** -- per-port vendor PN/SN, firmware version (via `mlxlink`)
- **Optical Diagnostics** -- RX/TX power, temperature per cable
- **GUID / LID Search** -- fabric-wide search by GUID or LID
- **IB Tracepath** -- visualize path between two HCAs (`ibtracert`)
- **Hardware Health** -- power, fan, temperature, CPU/memory per switch
- **Provision (DHCP + MLNX-OS ZTP)** -- zero-touch provisioning for new switches

## Status

**v0.4.0 — Phase 5b honest cleanup + Phase 6a/b (telemetry, registry, HW
checklist, Ask AI rewrite, demo dataset).**

What works:

- Full IB data collection pipeline (16 marker sections, 8 parsers, mock
mode via `LLDPQ_IB_MOCK=1`).
- 10 analysis pages (SM Status, P_Key, Multicast, QoS, SHARP, Link
Errors, Search, Tracepath, Topology, Transceiver) driven by per-fabric
IB JSON.
- Fabric overview dashboard (IB-focused, replaces the Cumulus dashboard).
- Ask AI (`ai.html` / `ai-api.sh`) -- IB-context system prompts +
IB-specific prompt chips (SM, Links, P_Keys, Multicast, SHARP,
Transceivers, Topology). Chat is disabled until an operator chooses a
provider (Ollama / OpenAI / Claude / Gemini) in Settings.
- Devices / Provision / Discover / DHCP / ZTP for MLNX-OS (Cumulus
`sw-base`, NVUE deploy and `onie-install` paths are explicitly
disabled in the IB edition; admins push MLNX-OS configs and images
manually).
- Optional UFM REST integration (alerts, system inventory, topology
cross-check, BER history Chart.js). Set `UFM_URL` / `UFM_TOKEN` to
enable.
- IB-focused alert engine (`check_alerts.py`): SM master loss, link
error severity, unreachable switches, hardware temp/fan.
- **Demo dataset** baked into the image: launch with `LLDPQ_DEMO=true`
and the container pre-populates a 4-spine + 8-leaf + 16-HCA fake fat-
tree (NDR, SHARP enabled, realistic problem ports) so the UI is full
the moment it opens. See "Demo mode" below.

What is intentionally not in v0.4.0:

- Optical menu item is hidden (Transceiver page covers per-module
health; BER history view is on the Telemetry page via Chart.js).
- Device.html `Capture` and `cl-support` tabs are placeholders --
MLNX-OS exposes `tcpdump` / `show tech-support` only via `_shell`,
which is not whitelisted in `ib-api.sh`.

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

LLDPq-IB connects to switches as `admin` (MLNX-OS default). Distribute the
container's SSH public key to each switch:

```bash
# On the LLDPq-IB host:
sudo docker exec lldpq-ib ssh-keygen -t ed25519 -N '' -f /home/lldpq/.ssh/id_ed25519

# Copy the public key (output of below) to each MLNX-OS switch:
sudo docker exec lldpq-ib cat /home/lldpq/.ssh/id_ed25519.pub

# On MLNX-OS:
switch (config) # ssh client user admin authorized-key sshv2 "ssh-ed25519 AAAA..."
```

### Optional: UFM Integration

NVIDIA's Unified Fabric Manager (UFM) provides additional fabric-wide telemetry,
alarms, and topology validation. LLDPq-IB can optionally consume UFM's REST API
to enrich monitoring. **UFM is not required** -- LLDPq-IB works fully without it.

When UFM is configured, the **UFM** sidebar entry shows:

- Connection status + UFM version
- Active alerts (with severity badges) -- you can filter and search
- Topology cross-check (which GUIDs we see locally that UFM doesn't, and vice versa)

To enable:

```bash
sudo docker run -d --name lldpq-ib \
  --network host --privileged \
  -e UFM_URL=https://ufm.example.com/ufmRest \
  -e UFM_TOKEN="$(echo -n 'admin:ufmpassword' | base64)" \
  -e UFM_VERIFY_TLS=false \
  lldpq-ib:latest
```

- `UFM_URL` -- base REST URL (typically ends in `/ufmRest`). Required.
- `UFM_TOKEN` -- base64-encoded `username:password` for HTTP Basic Auth. Required.
- `UFM_VERIFY_TLS` -- `true` to verify the UFM TLS certificate, `false` (default)
to accept self-signed certs.

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

