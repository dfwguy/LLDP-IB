#!/usr/bin/env python3
"""LLDPq-IB demo / showcase data generator.

Produces a self-consistent fake fabric (4 spines + 8 leaves + 16 HCAs, full
2-tier fat-tree, NDR 400 G, SHARP enabled) so the container UI is populated
the moment it boots, without needing any real MLNX-OS switches.

Outputs:

  <target>/ib_topology.json
  <target>/ib_sm_status.json
  <target>/ib_link_errors.json
  <target>/ib_pkey.json
  <target>/ib_multicast.json
  <target>/ib_qos.json
  <target>/ib_sharp_status.json
  <target>/transceiver_inventory.json
  <target>/log_summary.json
  <target>/ib_link_history.json
  <target>/assets.ini                                 (when --web-root)
  <target>/topology.dot                               (when --web-root)
  <target>/topology_config.yaml                       (when --web-root)
  <target>/hardware-data/<host>_hardware.txt         (12 switch files)

Usage:
  python3 tests/generate_demo_data.py \
      --target /var/www/html/monitor-results \
      --web-root /var/www/html

  python3 tests/generate_demo_data.py --target /tmp/demo

This script is also invoked at Docker build time when the demo dataset is
baked into the image (see Dockerfile).
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
from pathlib import Path

# ---------- constants ----------

SPINE_COUNT = 4
LEAF_COUNT = 8
HCAS_PER_LEAF = 2
HCA_COUNT = LEAF_COUNT * HCAS_PER_LEAF        # 16

SPINE_BASE_IP_OCTET = 10                       # 10.10.100.10..13
LEAF_BASE_IP_OCTET = 20                        # 10.10.100.20..27
HCA_BASE_IP_OCTET = 100                        # 10.10.100.100..115
IP_PREFIX = "10.10.100."

LINK_SPEED = "4xNDR"
LINK_RATE_GBPS = 400

# Switch model: NVIDIA Quantum-2 QM9700 (NDR, 64 x 400G OSFP cage on a leaf,
# but for the demo we use 32-port logical layout per leaf and 64 per spine.)
SPINE_PORTS = 64
LEAF_PORTS = 64
NV_OUI_PREFIX = "0002c903"


def guid(kind: str, idx: int) -> str:
    """Build a deterministic 64-bit GUID with NVIDIA OUI prefix.

    kind 'switch'/'host' just picks a different 8-bit group so the output is
    visually distinguishable; this is purely cosmetic for the demo.
    """
    group = {
        "spine": "0001",
        "leaf":  "0002",
        "hca":   "0003",
    }[kind]
    return f"0x{NV_OUI_PREFIX}{group}{idx:04x}"


def short_guid(g: str) -> str:
    return g if len(g) <= 14 else g[:10] + "…" + g[-4:]


def now_iso() -> str:
    return datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")


# ---------- model ----------


def make_nodes():
    """Return a list of {name, type, guid, lid, ip, model, fw} entries."""
    nodes = []
    lid = 1
    for i in range(1, SPINE_COUNT + 1):
        nodes.append({
            "hostname": f"ib-spine-{i:02d}",
            "type":     "switch",
            "role":     "spine",
            "guid":     guid("spine", i),
            "lid":      lid,
            "ip":       f"{IP_PREFIX}{SPINE_BASE_IP_OCTET + i - 1}",
            "model":    "QM9700",
            "fw":       "3.12.1004",
            "ports":    SPINE_PORTS,
            "serial":   f"MT2440X{10000 + i:05d}",
        })
        lid += 1
    for i in range(1, LEAF_COUNT + 1):
        nodes.append({
            "hostname": f"ib-leaf-{i:02d}",
            "type":     "switch",
            "role":     "leaf",
            "guid":     guid("leaf", i),
            "lid":      lid,
            "ip":       f"{IP_PREFIX}{LEAF_BASE_IP_OCTET + i - 1}",
            "model":    "QM9700",
            "fw":       "3.12.1004" if i % 4 else "3.12.0998",  # one outlier
            "ports":    LEAF_PORTS,
            "serial":   f"MT2440X{20000 + i:05d}",
        })
        lid += 1
    for i in range(1, HCA_COUNT + 1):
        nodes.append({
            "hostname": f"ib-host-{i:02d}",
            "type":     "hca",
            "role":     "host",
            "guid":     guid("hca", i),
            "lid":      lid,
            "ip":       f"{IP_PREFIX}{HCA_BASE_IP_OCTET + i - 1}",
            "model":    "ConnectX-7",
            "fw":       "28.39.1002",
            "ports":    2,
            "serial":   f"MT2429X{30000 + i:05d}",
        })
        lid += 1
    return nodes


def make_links(nodes):
    """Build a full 2-tier fat-tree:

    - every leaf has exactly one link to every spine (LEAF_COUNT * SPINE_COUNT
      = 32 uplinks; spine port 1..8, leaf port 1..4)
    - every host has exactly one link to its leaf (16 downlinks; leaf port 5..6)

    Returns a list of link dicts using the SAME schema that
    process_ib_topology.py emits, so the UI (topology / lldp / search /
    tracepath) can consume them directly:
        source_guid, source_port, source_type, source_desc,
        target_guid, target_port, target_type, target_desc,
        speed, discovered_from
    """
    spines = [n for n in nodes if n["role"] == "spine"]
    leaves = [n for n in nodes if n["role"] == "leaf"]
    hcas = [n for n in nodes if n["role"] == "host"]

    links = []

    # Spine -> Leaf links (source=spine on top, target=leaf below). The dagre
    # layout in topology/main.html ranks nodes top-to-bottom along edge
    # direction, so we orient edges so spines render at the top, leaves in
    # the middle, hosts at the bottom.
    for leaf_idx, leaf in enumerate(leaves, start=1):
        for spine_idx, spine in enumerate(spines, start=1):
            links.append({
                "source_guid": spine["guid"],
                "source_port": leaf_idx,                  # spine port -> this leaf
                "source_type": "switch",
                "source_desc": spine["hostname"],
                "target_guid": leaf["guid"],
                "target_port": spine_idx,                 # leaf port -> this spine
                "target_type": "switch",
                "target_desc": leaf["hostname"],
                "speed":       LINK_SPEED,
                "discovered_from": spine["hostname"],
            })

    # Leaf -> Host links (source=leaf on top, target=host at bottom)
    for h_idx, hca in enumerate(hcas):
        leaf_idx = h_idx // HCAS_PER_LEAF
        leaf = leaves[leaf_idx]
        local_port = (h_idx % HCAS_PER_LEAF) + 5         # leaf IB1/5..6
        links.append({
            "source_guid": leaf["guid"],
            "source_port": local_port,
            "source_type": "switch",
            "source_desc": leaf["hostname"],
            "target_guid": hca["guid"],
            "target_port": 1,                             # HCA port 1
            "target_type": "hca",
            "target_desc": hca["hostname"],
            "speed":       LINK_SPEED,
            "discovered_from": leaf["hostname"],
        })

    return links


# ---------- per-section JSON ----------


def make_topology(nodes, links):
    """Emit ib_topology.json in the SAME shape process_ib_topology.py writes:
       nodes:  description, type, guid, lid (+ extra fields hostname/role/model
               kept for the AI / Assets pages that look them up by hostname)
       links:  source_guid / source_port / source_desc / target_guid /
               target_port / target_desc / speed / discovered_from
    """
    switches = sum(1 for n in nodes if n["type"] == "switch")
    hcas = sum(1 for n in nodes if n["type"] == "hca")
    return {
        "generated_at": now_iso(),
        "nodes": [{
            "description": n["hostname"],   # UI prefers this; we use hostname
            "type":        n["type"],
            "guid":        n["guid"],
            "lid":         n["lid"],
            # extras kept for downstream code paths that look up by hostname
            "hostname":    n["hostname"],
            "role":        n["role"],
            "model":       n["model"],
        } for n in nodes],
        "links": links,
        "summary": {
            "total_nodes":         len(nodes),
            "total_links":         len(links),
            "switches":            switches,
            "hcas":                hcas,
            "routers":             0,
            "orphan_count":        0,
            "speed_distribution":  {LINK_SPEED: len(links)},
        },
    }


def make_sm_status(nodes):
    spines = [n for n in nodes if n["role"] == "spine"]
    master = spines[0]
    standby = spines[1]
    # Other 2 spines and all leaves are Not Active
    sms = [
        {"guid": master["guid"],  "hostname": master["hostname"],  "state": "Master",     "priority": 1, "lid": master["lid"]},
        {"guid": standby["guid"], "hostname": standby["hostname"], "state": "Standby",    "priority": 2, "lid": standby["lid"]},
    ]
    # one "disagreement" for demo realism: a third SM briefly thought it was master
    return {
        "generated_at":    now_iso(),
        "master_guid":     master["guid"],
        "master_hostname": master["hostname"],
        "last_sweep_seconds": 12,
        "sms": sms,
        "disagreements": [{
            "node":              spines[2]["hostname"],
            "guid":              spines[2]["guid"],
            "claimed_master":    spines[2]["guid"],
            "actual_master":     master["guid"],
            "observed_at":       now_iso(),
        }],
        "summary": {
            "total_sms":          len(sms),
            "master_count":       1,
            "standby_count":      1,
            "has_master":         True,
            "has_redundancy":     True,
            "disagreement_count": 1,
        },
    }


def make_link_errors(nodes, links):
    """3 problematic ports out of 48: 1 critical, 2 warning."""
    leaves = [n for n in nodes if n["role"] == "leaf"]
    problems = [
        {
            "device":           leaves[2]["hostname"],  # ib-leaf-03
            "port":             "IB1/12",
            "peer":             "ib-host-05",
            "severity":         "critical",
            "symbol_errors":    15234,
            "link_downed":      0,
            "rcv_errors":       2150,
            "xmit_discards":    34,
            "first_seen":       now_iso(),
            "note":             "Symbol errors climbing > 10k in the last hour",
        },
        {
            "device":           leaves[4]["hostname"],  # ib-leaf-05
            "port":             "IB1/8",
            "peer":             "ib-spine-04",
            "severity":         "warning",
            "symbol_errors":    412,
            "link_downed":      3,
            "rcv_errors":       0,
            "xmit_discards":    0,
            "first_seen":       now_iso(),
            "note":             "3 LinkDowned events in the last 1h",
        },
        {
            "device":           leaves[6]["hostname"],  # ib-leaf-07
            "port":             "IB1/22",
            "peer":             "ib-host-13",
            "severity":         "warning",
            "symbol_errors":    0,
            "link_downed":      0,
            "rcv_errors":       87,
            "xmit_discards":    12,
            "first_seen":       now_iso(),
            "note":             "Sporadic PortRcvErrors observed",
        },
    ]

    monitored_ports = len(links)  # one entry per link
    return {
        "generated_at":  now_iso(),
        "problem_ports": problems,
        "summary": {
            "total_ports":     monitored_ports,
            "healthy":         monitored_ports - len(problems),
            "critical":        sum(1 for p in problems if p["severity"] == "critical"),
            "warning":         sum(1 for p in problems if p["severity"] == "warning"),
            "flapping":        1,         # ib-leaf-05 IB1/8 (3 LinkDowned)
            "critical_count":  sum(1 for p in problems if p["severity"] == "critical"),
            "warning_count":   sum(1 for p in problems if p["severity"] == "warning"),
            "flapping_1h":     1,
        },
    }


def make_link_history():
    """Internal counter-delta state, consumed only by the analyzer.

    Demo: store one historical sample per problem port so the trend column
    on the UI has something to render.
    """
    return {
        "generated_at": now_iso(),
        "samples": {
            "ib-leaf-03:IB1/12": {"symbol_errors": [4000, 9800, 15234], "ts": [1700000000, 1700001800, 1700003600]},
            "ib-leaf-05:IB1/8":  {"link_downed":   [0,    2,     3],     "ts": [1700000000, 1700001800, 1700003600]},
            "ib-leaf-07:IB1/22": {"rcv_errors":    [0,    34,    87],    "ts": [1700000000, 1700001800, 1700003600]},
        },
    }


def make_pkey(nodes):
    """3 partitions: default (all), training (all hosts), storage (8 hosts)."""
    hosts = [n for n in nodes if n["role"] == "host"]
    switches = [n for n in nodes if n["type"] == "switch"]
    partitions = {
        "0x7fff": {
            "name":     "default (full membership)",
            "members":  [n["guid"] for n in (switches + hosts)],
            "member_count": len(switches) + len(hosts),
            "type":     "full",
        },
        "0x8001": {
            "name":     "ai-training",
            "members":  [h["guid"] for h in hosts],
            "member_count": len(hosts),
            "type":     "full",
        },
        "0x8002": {
            "name":     "storage",
            "members":  [h["guid"] for h in hosts[:8]],
            "member_count": 8,
            "type":     "limited",
        },
    }
    per_device = {}
    for sw in switches:
        per_device[sw["hostname"]] = list(partitions.keys())
    return {
        "generated_at": now_iso(),
        "pkeys":        partitions,
        "per_device":   per_device,
        "summary": {
            "total_pkeys":        len(partitions),
            "partition_count":    len(partitions),
            "devices_polled":     len(switches),
            "inconsistencies":    0,
            "inconsistency_count": 0,
        },
    }


def make_multicast():
    return {
        "generated_at": now_iso(),
        "groups": [
            {"mgid": "ff12:401b:ffff::0000:0001", "mlid": "0xc000", "pkey": "0x7fff", "members": 16, "kind": "IPoIB-default"},
            {"mgid": "ff12:401b:ffff::0000:0002", "mlid": "0xc001", "pkey": "0x8001", "members": 16, "kind": "NCCL-ring"},
            {"mgid": "ff12:401b:ffff::0000:0003", "mlid": "0xc002", "pkey": "0x8001", "members": 16, "kind": "MPI-broadcast"},
        ],
        "summary": {
            "total_groups":      3,
            "group_count":       3,
            "devices_polled":    SPINE_COUNT + LEAF_COUNT,
            "pkey_distribution": {"0x7fff": 1, "0x8001": 2},
        },
    }


def make_qos(nodes):
    switches = [n for n in nodes if n["type"] == "switch"]
    return {
        "generated_at": now_iso(),
        "profiles": [
            {
                "name":      "default",
                "sl_to_vl":  {str(sl): sl for sl in range(8)},
                "applied_on": [s["hostname"] for s in switches],
            },
            {
                "name":      "ai-training-low-latency",
                "sl_to_vl":  {"0": 0, "1": 1, "2": 2, "3": 3},
                "applied_on": [s["hostname"] for s in switches if s["role"] == "leaf"],
            },
        ],
        "per_device": {s["hostname"]: ["default", "ai-training-low-latency"] for s in switches},
        "summary": {
            "total_profiles":      2,
            "profile_count":       2,
            "devices_polled":      len(switches),
            "inconsistencies":     0,
            "inconsistency_count": 0,
        },
    }


def make_sharp(nodes):
    """SHARP enabled; root on the master SM spine, 4 aggregation trees."""
    spines = [n for n in nodes if n["role"] == "spine"]
    root = spines[0]
    trees = [
        {
            "tree_id":  i,
            "root":     root["hostname"],
            "root_guid": root["guid"],
            "members":  16,
            "max_payload_bytes": 4096,
        }
        for i in range(1, 5)
    ]
    return {
        "generated_at": now_iso(),
        "enabled":      True,
        "version":      "3.7.0",
        "nodes": [
            {"hostname": s["hostname"], "guid": s["guid"], "role": "aggregator", "trees": 4 if s == root else 2}
            for s in spines
        ],
        "trees": trees,
        "summary": {
            "node_count":               len(spines),
            "total_aggregation_nodes":  len(spines),
            "tree_count":               len(trees),
            "devices_with_sharp":       len(spines),
        },
    }


def make_transceivers(links):
    """One entry per port that participates in a link.

    Demo: mostly MMA1Z00-NS400 on FW 0.32.0998; introduce ONE mixed-FW model
    (one cable at 0.32.0994) so transceiver page has a yellow row.
    """
    modules = []
    fw_default = "0.32.0998"
    fw_outlier = "0.32.0994"

    seen = set()
    for link in links:
        for end in ("source", "target"):
            desc = link[f"{end}_desc"]
            port = link[f"{end}_port"]
            key = (desc, port)
            if key in seen:
                continue
            seen.add(key)
            modules.append({
                "device":       desc,
                "port":         f"IB1/{port}",
                "vendor":       "NVIDIA",
                "vendor_pn":    "MMA1Z00-NS400",
                "vendor_sn":    f"NV{abs(hash(key)) % 10**9:09d}",
                "vendor_rev":   "A1",
                "fw_version":   fw_default,
                "cable_length": "2m",
                "speed":        LINK_SPEED,
                "status":       "ok",
            })

    # Make ONE module a different FW so the model is "mixed FW"
    if modules:
        modules[0]["fw_version"] = fw_outlier

    # Count fw per model
    by_model = {}
    for m in modules:
        by_model.setdefault(m["vendor_pn"], {}).setdefault(m["fw_version"], 0)
        by_model[m["vendor_pn"]][m["fw_version"]] += 1

    mixed = [pn for pn, fws in by_model.items() if len(fws) > 1]

    return {
        "generated_at": now_iso(),
        "modules":      modules,
        "summary": {
            "total_modules":          len(modules),
            "modules_count":          len(modules),
            "unique_models":          len(by_model),
            "devices_with_modules":   SPINE_COUNT + LEAF_COUNT + HCA_COUNT,
            "fw_versions":            by_model,
            "mixed_fw_models":        mixed,
            "mixed_firmware_models":  len(mixed),
            "status_counts":          {"ok": len(modules)},
        },
    }


def make_log_summary():
    return {
        "generated_at": now_iso(),
        "critical": 0,
        "error":    2,
        "warning":  8,
        "info":     120,
        "top_messages": [
            {"severity": "error",   "device": "ib-leaf-03", "count": 6,  "sample": "PortRcvSwitchRelayErrors increasing on IB1/12"},
            {"severity": "warning", "device": "ib-leaf-05", "count": 3,  "sample": "Link downed on IB1/8 (peer ib-spine-04)"},
        ],
    }


def make_assets_ini(nodes):
    """assets.ini in the exact format ib-assets.sh writes (tab-separated, 7
    columns + header):
        # LLDPq-IB Assets - <date>
        # DEVICE-NAME    IP    MODEL    SERIAL    RELEASE    OS    UPTIME
        hostname\tip\tmodel\tserial\trelease\tos\tuptime
    Only reachable devices are listed (the page treats unlisted devices.yaml
    entries as unreachable). For the demo we list every switch -- HCAs are
    intentionally excluded because LLDPq-IB does not probe hosts.
    """
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
    lines = [
        f"# LLDPq-IB Assets - {ts}",
        "# DEVICE-NAME\tIP\tMODEL\tSERIAL\tRELEASE\tOS\tUPTIME",
    ]
    # Switches reachable in demo. HCAs are intentionally NOT in assets.ini
    # (they would appear in topology only). Uptime is faked deterministically
    # to give the Assets page something interesting in the column.
    for i, n in enumerate(n for n in nodes if n["type"] == "switch"):
        uptime = f"{2 + i % 5}d {3 + i % 12}h"
        lines.append(
            f"{n['hostname']}\t{n['ip']}\t{n['model']}\t{n['serial']}\t"
            f"{n['fw']}\tMLNX-OS\t{uptime}"
        )
    return "\n".join(lines) + "\n"


def make_topology_dot(nodes, links):
    """Graphviz dot for the LLDPq topology renderer + wiring validator.

    Demo realism: we deliberately diverge the DOT from the actual links in
    THREE places so the IB Network Wiring Validation page surfaces:
      - 1 MISWIRED port  (DOT says peer A, actual says peer B)
      - 1 CABLE MISSING  (DOT has the link, actual does not)
      - 1 UNEXPECTED     (actual has the link, DOT does not)
    The total mismatch count is kept tiny so the page is still mostly green.
    """
    # Build the directed lines first, then inject 2 deliberate edits.
    dot_lines = []
    for link in links:
        dot_lines.append(
            f'    "{link["source_desc"]}":"IB1/{link["source_port"]}" -- '
            f'"{link["target_desc"]}":"IB1/{link["target_port"]}";'
        )

    # --- 1. MISWIRED ---
    # Take the link "ib-leaf-04:IB1/2 -- ib-spine-02:IB1/4" and pretend the
    # design called for spine-03 instead. Actual JSON still has spine-02.
    target_actual = '"ib-spine-02":"IB1/4" -- "ib-leaf-04":"IB1/2"'  # spine view
    miswired      = '"ib-spine-03":"IB1/4" -- "ib-leaf-04":"IB1/2"'
    for i, line in enumerate(dot_lines):
        if target_actual in line:
            dot_lines[i] = f'    {miswired};   # demo: MISWIRED (designed spine-03, wired to spine-02)'
            break

    # --- 2. CABLE MISSING ---
    # Add a DOT-only link to ib-leaf-08:IB1/20 that the actual JSON does not
    # have. The validator will mark it CABLE MISSING.
    dot_lines.append(
        '    "ib-spine-04":"IB1/20" -- "ib-leaf-08":"IB1/20";   '
        '# demo: CABLE MISSING (planned but ibnetdiscover did not see it)'
    )

    # --- 3. UNEXPECTED ---
    # Append a synthetic link to the JSON-side (handled in make_topology by
    # editing `links` before this point). We do that in write_all() by
    # mutating the list -- see the call site.

    out = ["graph fabric {", "    rankdir=TB;", "    node [shape=box, style=filled];", ""]
    for n in nodes:
        color = {"spine": "#76b900", "leaf": "#4fc3f7", "host": "#ce93d8"}.get(n["role"], "#888888")
        out.append(f'    "{n["hostname"]}" [fillcolor="{color}", fontcolor="#000"];')
    out.append("")
    out.extend(dot_lines)
    out.append("}")
    return "\n".join(out) + "\n"


def inject_unexpected_link(links, nodes):
    """Add an extra link to the actual-topology JSON that is NOT in the DOT,
    so the validator shows one UNEXPECTED row. Connects an unused leaf port
    pair so it doesn't clobber a real demo link."""
    leaves = [n for n in nodes if n["role"] == "leaf"]
    if len(leaves) < 2:
        return
    a, b = leaves[0], leaves[1]
    links.append({
        "source_guid": a["guid"],
        "source_port": 30,
        "source_type": "switch",
        "source_desc": a["hostname"],
        "target_guid": b["guid"],
        "target_port": 30,
        "target_type": "switch",
        "target_desc": b["hostname"],
        "speed":       LINK_SPEED,
        "discovered_from": a["hostname"],
        "_demo_unexpected": True,
    })


def make_topology_config(nodes):
    """topology_config.yaml -- display ordering (LLDPq uses this for layout)."""
    spines = [n["hostname"] for n in nodes if n["role"] == "spine"]
    leaves = [n["hostname"] for n in nodes if n["role"] == "leaf"]
    hosts  = [n["hostname"] for n in nodes if n["role"] == "host"]
    return (
        "# Auto-generated demo topology ordering.\n"
        "# Override with your own ordering on real deployments.\n"
        "rows:\n"
        f"  - {{role: spine, label: \"Spine (NDR)\", members: {spines}}}\n"
        f"  - {{role: leaf,  label: \"Leaf  (NDR)\", members: {leaves}}}\n"
        f"  - {{role: host,  label: \"HCA hosts\",  members: {hosts}}}\n"
    )


def make_hardware_files(target_dir, nodes):
    """Write per-switch <host>_hardware.txt files with synthetic data."""
    hw_dir = target_dir / "hardware-data"
    hw_dir.mkdir(parents=True, exist_ok=True)
    for n in nodes:
        if n["type"] != "switch":
            continue
        cpu = 52 if n["role"] == "spine" else 49
        body = (
            f"# Generated by tests/generate_demo_data.py for {n['hostname']}\n"
            f"# Section: IB_HARDWARE (synthetic)\n"
            "\n"
            f"Hostname:        {n['hostname']}\n"
            f"Model:           {n['model']}\n"
            f"Serial:          {n['serial']}\n"
            f"OS Version:      MLNX-OS {n['fw']}\n"
            "\n"
            "----------------------------- Temperature -----------------------------\n"
            f"CPU temp:        +{cpu}.0\u00b0C  (warn:75 crit:85)\n"
            f"ASIC temp:       +{cpu + 18}.0\u00b0C  (warn:80 crit:90)\n"
            "\n"
            "-------------------------------- Fans ---------------------------------\n"
            "FAN1 (front):    13200 RPM\n"
            "FAN2 (front):    13180 RPM\n"
            "FAN3 (rear):     12950 RPM\n"
            "FAN4 (rear):     12990 RPM\n"
            "\n"
            "------------------------------- Power ---------------------------------\n"
            "PSU1:            OK  (1300W in,  720W out, 82% efficient)\n"
            "PSU2:            OK  (1300W in,  720W out, 82% efficient)\n"
        )
        (hw_dir / f"{n['hostname']}_hardware.txt").write_text(body)


# ---------- driver ----------


def write_all(target_dir: Path, web_root: Path | None):
    target_dir.mkdir(parents=True, exist_ok=True)

    nodes = make_nodes()
    links = make_links(nodes)
    # Inject one "UNEXPECTED" link (in actual JSON but not in DOT) so the
    # wiring validator demo shows green + yellow + red together.
    inject_unexpected_link(links, nodes)

    bundles = {
        "ib_topology.json":          make_topology(nodes, links),
        "ib_sm_status.json":         make_sm_status(nodes),
        "ib_link_errors.json":       make_link_errors(nodes, links),
        "ib_link_history.json":      make_link_history(),
        "ib_pkey.json":              make_pkey(nodes),
        "ib_multicast.json":         make_multicast(),
        "ib_qos.json":               make_qos(nodes),
        "ib_sharp_status.json":      make_sharp(nodes),
        "transceiver_inventory.json": make_transceivers(links),
        "log_summary.json":          make_log_summary(),
    }

    for name, data in bundles.items():
        (target_dir / name).write_text(json.dumps(data, indent=2) + "\n")

    make_hardware_files(target_dir, nodes)

    if web_root is not None:
        web_root.mkdir(parents=True, exist_ok=True)
        (web_root / "assets.ini").write_text(make_assets_ini(nodes))
        (web_root / "topology.dot").write_text(make_topology_dot(nodes, links))
        (web_root / "topology_config.yaml").write_text(make_topology_config(nodes))

    print(f"Wrote {len(bundles)} JSON + hardware-data/* to {target_dir}")
    if web_root is not None:
        print(f"Wrote assets.ini, topology.dot, topology_config.yaml to {web_root}")


def main():
    parser = argparse.ArgumentParser(description="LLDPq-IB demo data generator")
    parser.add_argument("--target", required=True, help="Target dir for monitor-results JSON")
    parser.add_argument("--web-root",
                        help="Web root for assets.ini / topology.dot (optional)")
    args = parser.parse_args()
    write_all(Path(args.target), Path(args.web_root) if args.web_root else None)


if __name__ == "__main__":
    main()
