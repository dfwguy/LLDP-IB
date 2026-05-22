# LLDPq InfiniBand Edition

```
██╗     ██╗     ██████╗ ██████╗  ██████╗     ██╗██████╗
██║     ██║     ██╔══██╗██╔══██╗██╔═══██╗    ██║██╔══██╗
██║     ██║     ██║  ██║██████╔╝██║   ██║    ██║██████╔╝
██║     ██║     ██║  ██║██╔═══╝ ██║▄▄ ██║    ██║██╔══██╗
██████╗ ██████╗ ██████╔╝██║      ╚██████╔╝    ██║██████╔╝
╚═════╝ ╚═════╝ ╚═════╝ ╚═╝       ╚══▀▀═╝     ╚═╝╚═════╝
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

**Phase 1 (Foundation)** -- repo bootstrap complete. Web UI shell ready, IB data
collection scripts pending (Phase 2). See [.cursor/ROADMAP.md](./.cursor/ROADMAP.md)
for the full plan.

## Quick Start (Docker only)

LLDPq-IB is **Docker-only**. No `install.sh`, no native install.

```bash
# Build the image (once stable images are published, you'll be able to pull instead)
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
