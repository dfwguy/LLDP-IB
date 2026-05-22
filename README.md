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
docker run -d --name lldpq-ib \
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

LLDPq-IB is **Docker-only**. There is no `install.sh`, no native install.

```bash
# Option A — pull a published image (once available)
docker pull lldpq/lldpq-ib:latest

# Option B — build from source
git clone https://github.com/aliaydemir/lldpq-ib-src.git
cd lldpq-ib-src
docker build -t lldpq-ib:latest .

# Run
docker run -d --name lldpq-ib \
  --network host --privileged \
  -v lldpq-ib-data:/home/lldpq/lldpq/monitor-results \
  -v lldpq-ib-config:/home/lldpq/lldpq \
  -v lldpq-ib-ssh:/home/lldpq/.ssh \
  lldpq-ib:latest
```

### Publishing your own image

If you keep a private Docker registry, the repo ships a helper script that
tags and pushes the image with both `:VERSION` and `:latest` tags after a
successful `docker build`:

```bash
# 1. Build once
./docker/docker-build.sh

# 2. Push to your registry
LLDPQ_REGISTRY=registry.example.com/lldpq ./docker/docker-push.sh
```

Equivalent manual flow (no helper):

```bash
docker tag lldpq-ib:latest registry.example.com/lldpq/lldpq-ib:0.4.0
docker tag lldpq-ib:latest registry.example.com/lldpq/lldpq-ib:latest
docker push registry.example.com/lldpq/lldpq-ib:0.4.0
docker push registry.example.com/lldpq/lldpq-ib:latest
```

On the deployment host:

```bash
docker pull registry.example.com/lldpq/lldpq-ib:latest
docker run -d --name lldpq-ib --network host --privileged \
  -v lldpq-ib-data:/home/lldpq/lldpq/monitor-results \
  -v lldpq-ib-config:/home/lldpq/lldpq \
  -v lldpq-ib-ssh:/home/lldpq/.ssh \
  registry.example.com/lldpq/lldpq-ib:latest
```

Builds are amd64-only — the Dockerfile expects to run on an x86_64 host.

Open `http://<host-ip>` in your browser. Default credentials:
- `admin` / `admin` -- full access
- `operator` / `operator` -- read-only

**Change these passwords on first login.**

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
docker exec lldpq-ib ssh-keygen -t ed25519 -N '' -f /home/lldpq/.ssh/id_ed25519

# Copy the public key (output of below) to each MLNX-OS switch:
docker exec lldpq-ib cat /home/lldpq/.ssh/id_ed25519.pub

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
docker run -d --name lldpq-ib \
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

| Aspect | LLDPq (Ethernet) | LLDPq-IB |
|---|---|---|
| Switch OS | Cumulus Linux (NVUE/FRR) | MLNX-OS |
| L2 address | MAC | GUID |
| L3 address | IP | LID |
| Segmentation | VLAN | P_Key |
| Routing protocol | BGP, OSPF | Subnet Manager |
| Topology discovery | LLDP | `ibnetdiscover` |
| Link flap counter | `carrier_changes` | `LinkDownedCounter` |
| Config management | Ansible (optional) | None (monitoring-only) |
| Deployment | install.sh OR Docker | **Docker-only** |

## Out of Scope

- **Configuration management** -- LLDPq-IB does NOT push config to switches.
  Use UFM or your IaC tool of choice for that.
- **HCA (host) monitoring** -- only switch-side. Use `mlnx-tools` on hosts.
- **Multi-subnet fabrics** -- single `infiniband-default` subnet assumed.

## License

MIT License -- see [LICENSE](LICENSE).
