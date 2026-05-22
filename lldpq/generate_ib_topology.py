#!/usr/bin/env python3
"""generate_ib_topology.py - IB Topology Generator for LLDPq-IB
=================================================================

Reads:
  - assets.ini          (device inventory + IP/model/serial/version)
  - devices.yaml        (endpoint_hosts patterns for HCAs)
  - ib_topology.json    (actual links from ibnetdiscover, written by
                         process_ib_topology.py)
  - ib_link_errors.json (per-port severity, used to flag DOWN ports)
  - topology.dot        (expected wiring)
  - topology_config.yaml (per-pattern layer + icon mapping)

Writes:
  - /var/www/html/topology/topology.js   (var topologyData = {...};)

The output schema is byte-compatible with the LLDPq Ethernet cyto-app.js
renderer:
  nodes[]: id, name, icon, layerSortPreference, primaryIP, model,
           serial_number, version, dcimDeviceLink
  links[]: id, source, target, srcDevice, srcIfName, srcPortStatus,
           srcPortSpeed, tgtDevice, tgtIfName, tgtPortStatus, tgtPortSpeed,
           is_missing ("no"/"yes"/"fail")

Run from inside /home/lldpq/lldpq (where assets.ini / devices.yaml / monitor-
results live) -- or pass --web-root + --lldpq-dir to point elsewhere.

Copyright (c) 2024-2026 LLDPq Project - Licensed under MIT License
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from datetime import datetime

try:
    import yaml
except ImportError:
    yaml = None


# ---------- config / device categorisation ----------

DEFAULT_CONFIG = {
    "device_categories": [
        {"pattern": r"^ib-core-|core",  "layer": 1, "icon": "router"},
        {"pattern": r"^ib-spine-|spine","layer": 2, "icon": "switch"},
        {"pattern": r"^ib-leaf-|leaf",  "layer": 3, "icon": "switch"},
        {"pattern": r"^ib-host-|host|dgx|gpu", "layer": 4, "icon": "host"},
        {"pattern": r"switch",          "layer": 3, "icon": "switch"},
    ],
    "default": {"layer": 9, "icon": "host"},
}


def load_topology_config(path):
    if not yaml or not os.path.exists(path):
        return DEFAULT_CONFIG
    try:
        with open(path) as f:
            cfg = yaml.safe_load(f) or {}
        if cfg.get("device_categories"):
            return cfg
        return DEFAULT_CONFIG
    except Exception as e:
        print(f"WARN: cannot parse {path}: {e}", file=sys.stderr)
        return DEFAULT_CONFIG


def categorize_device(device_name, config):
    lower = device_name.lower()
    # special_rules first
    for rule in config.get("special_rules", []) or []:
        try:
            if re.search(rule["pattern"], device_name, re.IGNORECASE):
                if rule.get("type") == "even_odd_suffix":
                    try:
                        n = int(device_name.split("-")[-1])
                        layer = rule["even_layer"] if n % 2 == 0 else rule["odd_layer"]
                        return layer, rule["icon"]
                    except (ValueError, IndexError):
                        break
        except re.error:
            pass
    for cat in config.get("device_categories", []) or []:
        try:
            if re.search(cat["pattern"], lower):
                return cat["layer"], cat["icon"]
        except re.error:
            if cat["pattern"] in lower:
                return cat["layer"], cat["icon"]
    d = config.get("default") or {"layer": 9, "icon": "host"}
    return d.get("layer", 9), d.get("icon", "host")


# ---------- assets.ini ----------

def parse_assets_file(path):
    """Tab-separated 7 cols: hostname IP MODEL SERIAL RELEASE OS UPTIME."""
    devices = {}
    if not os.path.exists(path):
        return devices
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                # Tolerant split: ib-assets.sh writes \t, but be safe
                parts = re.split(r"\t+|\s{2,}", line)
                if len(parts) < 2:
                    continue
                name = parts[0]
                if name in ("DEVICE-NAME",):
                    continue
                devices[name] = {
                    "primaryIP":     parts[1] if len(parts) > 1 else "",
                    "model":         parts[2] if len(parts) > 2 else "",
                    "serial_number": parts[3] if len(parts) > 3 else "",
                    "version":       parts[4] if len(parts) > 4 else "",
                    "os":            parts[5] if len(parts) > 5 else "",
                    "uptime":        parts[6] if len(parts) > 6 else "",
                }
    except Exception as e:
        print(f"WARN: cannot parse {path}: {e}", file=sys.stderr)
    return devices


# ---------- devices.yaml endpoint_hosts ----------

def parse_endpoint_hosts(devices_yaml_path):
    host_names, patterns = set(), []
    if not yaml or not os.path.exists(devices_yaml_path):
        return host_names, patterns
    try:
        with open(devices_yaml_path) as f:
            cfg = yaml.safe_load(f) or {}
        for entry in cfg.get("endpoint_hosts", []) or []:
            if not entry or not isinstance(entry, str):
                continue
            e = entry.strip()
            if "*" in e:
                patterns.append(re.compile("^" + e.replace("*", ".*") + "$", re.IGNORECASE))
            else:
                host_names.add(e)
    except Exception as e:
        print(f"WARN: cannot parse {devices_yaml_path}: {e}", file=sys.stderr)
    return host_names, patterns


# ---------- ib_topology.json ----------

def load_ib_topology(path):
    """Return ({guid -> node dict from ib_topology.json}, links[])."""
    if not os.path.exists(path):
        return {}, []
    try:
        with open(path) as f:
            data = json.load(f)
    except Exception as e:
        print(f"WARN: cannot parse {path}: {e}", file=sys.stderr)
        return {}, []
    by_guid = {n.get("guid"): n for n in (data.get("nodes") or []) if n.get("guid")}
    return by_guid, (data.get("links") or [])


def load_link_errors(path):
    """Return: { (hostname, "IB1/N") -> severity }."""
    if not os.path.exists(path):
        return {}
    try:
        with open(path) as f:
            data = json.load(f)
    except Exception:
        return {}
    out = {}
    for p in data.get("problem_ports") or []:
        host = p.get("device", "")
        port = p.get("port", "")
        sev = (p.get("severity") or "").lower()
        out[(host, port)] = sev
    return out


# ---------- topology.dot ----------

def parse_topology_dot(path):
    """Return list of (a, aPort, b, bPort) tuples, undirected."""
    edges = []
    if not os.path.exists(path):
        return edges
    try:
        with open(path) as f:
            text = f.read()
    except Exception:
        return edges
    text = re.sub(r"/\*[\s\S]*?\*/", "", text)
    for line in text.splitlines():
        line = line.strip()
        if "--" not in line:
            continue
        m = re.findall(r'"([^"]+)"', line)
        if len(m) == 4:
            edges.append((m[0], m[1], m[2], m[3]))
    return edges


# ---------- helpers ----------

def port_name(p):
    if p is None or p == "":
        return ""
    s = str(p).strip()
    return s if re.match(r"^IB\d+/", s, re.IGNORECASE) else f"IB1/{s}"


def speed_label(s):
    """Convert "4xNDR" / "4xHDR" / "1xEDR" etc. to a readable bandwidth string."""
    if not s:
        return "N/A"
    s_up = s.upper()
    table = {
        "NDR": 100, "HDR": 50, "EDR": 25, "FDR": 14, "QDR": 10, "DDR": 5, "SDR": 2.5,
    }
    m = re.match(r"(\d+)X([A-Z]+)", s_up)
    if m:
        lanes, kind = int(m.group(1)), m.group(2)
        per = table.get(kind, 0)
        total_gbps = int(lanes * per * 4)  # IB encoding: per-lane Gbps already adjusted
        if total_gbps:
            return f"{total_gbps}Gbps"
    return s


# ---------- main build ----------

def build_topology(
        assets_path,
        devices_yaml_path,
        ib_topology_path,
        link_errors_path,
        dot_path,
        topology_config_path,
        ):
    config = load_topology_config(topology_config_path)
    device_info = parse_assets_file(assets_path)
    host_names, host_patterns = parse_endpoint_hosts(devices_yaml_path)
    guid_to_node, ib_links = load_ib_topology(ib_topology_path)
    port_errors = load_link_errors(link_errors_path)
    dot_edges = parse_topology_dot(dot_path)

    # ----- nodes -----
    nodes = []
    node_id_by_name = {}

    # 1) Every device in assets.ini (assets-known switches)
    for name, info in device_info.items():
        if name in node_id_by_name:
            continue
        layer, icon = categorize_device(name, config)
        nid = len(nodes)
        node_id_by_name[name] = nid
        nodes.append({
            "id":             nid,
            "name":           name,
            "icon":           icon,
            "layerSortPreference": layer,
            "primaryIP":      info.get("primaryIP", "N/A") or "N/A",
            "model":          info.get("model", "N/A") or "N/A",
            "serial_number":  info.get("serial_number", "N/A") or "N/A",
            "version":        info.get("version", "N/A") or "N/A",
            "dcimDeviceLink": f"/device.html?device={name}",
        })

    # 2) Every node in ib_topology.json that isn't already in assets (HCAs)
    for guid, node in guid_to_node.items():
        name = node.get("description") or node.get("hostname")
        if not name or name in node_id_by_name:
            continue
        layer, icon = categorize_device(name, config)
        nid = len(nodes)
        node_id_by_name[name] = nid
        nodes.append({
            "id":             nid,
            "name":           name,
            "icon":           icon,
            "layerSortPreference": layer,
            "primaryIP":      "N/A",
            "model":          node.get("model", "N/A") or "N/A",
            "serial_number":  "N/A",
            "version":        "N/A",
            "dcimDeviceLink": f"/device.html?device={name}",
        })

    # 3) Endpoint_hosts patterns: any hostname matched but not yet a node
    if host_patterns:
        scanned = set()
        for n in nodes:
            scanned.add(n["name"])
        # also scan ib_topology nodes / dot edges for candidates
        for n in guid_to_node.values():
            d = n.get("description")
            if d:
                scanned.add(d)
        for a, _, b, _ in dot_edges:
            scanned.add(a); scanned.add(b)
        for hn in scanned:
            if hn in node_id_by_name:
                continue
            if any(pat.match(hn) for pat in host_patterns):
                layer, icon = categorize_device(hn, config)
                nid = len(nodes)
                node_id_by_name[hn] = nid
                nodes.append({
                    "id":             nid,
                    "name":           hn,
                    "icon":           icon,
                    "layerSortPreference": layer,
                    "primaryIP":      "N/A",
                    "model":          "N/A",
                    "serial_number":  "N/A",
                    "version":        "N/A",
                    "dcimDeviceLink": f"/device.html?device={hn}",
                })

    # 4) Exact endpoint_hosts entries that still aren't present
    for hn in host_names:
        if hn not in node_id_by_name:
            layer, icon = categorize_device(hn, config)
            nid = len(nodes)
            node_id_by_name[hn] = nid
            nodes.append({
                "id":             nid,
                "name":           hn,
                "icon":           icon,
                "layerSortPreference": layer,
                "primaryIP":      "N/A",
                "model":          "N/A",
                "serial_number":  "N/A",
                "version":        "N/A",
                "dcimDeviceLink": f"/device.html?device={hn}",
            })

    # ----- links -----
    # Use a normalised key to dedupe bidirectional links
    def edge_key(sd, sp, td, tp):
        a = (sd, sp); b = (td, tp)
        return (a, b) if a <= b else (b, a)

    actual_keys = set()      # for is_missing detection against DOT
    links = []
    next_link_id = 0

    # Make sure every device referenced by an ib_topology link has a node id
    def ensure_node(name, default_icon="switch"):
        if name in node_id_by_name:
            return node_id_by_name[name]
        layer, icon = categorize_device(name, config)
        if not icon:
            icon = default_icon
        nid = len(nodes)
        node_id_by_name[name] = nid
        nodes.append({
            "id":             nid,
            "name":           name,
            "icon":           icon,
            "layerSortPreference": layer,
            "primaryIP":      "N/A",
            "model":          "N/A",
            "serial_number":  "N/A",
            "version":        "N/A",
            "dcimDeviceLink": f"/device.html?device={name}",
        })
        return nid

    speed_for_link = {}

    for L in ib_links:
        sdev = L.get("source_desc") or ""
        tdev = L.get("target_desc") or ""
        sp = port_name(L.get("source_port"))
        tp = port_name(L.get("target_port"))
        if not (sdev and tdev and sp and tp):
            continue
        sid = ensure_node(sdev, default_icon=L.get("source_type", "switch"))
        tid = ensure_node(tdev, default_icon=L.get("target_type", "switch"))

        sev_src = port_errors.get((sdev, sp))
        sev_tgt = port_errors.get((tdev, tp))
        # port status: UP unless we know about it being problematic
        src_status = "DOWN" if sev_src == "critical" else "UP"
        tgt_status = "DOWN" if sev_tgt == "critical" else "UP"

        speed = speed_label(L.get("speed"))
        links.append({
            "id":            next_link_id,
            "source":        sid,
            "target":        tid,
            "srcDevice":     sdev,
            "srcIfName":     sp,
            "srcPortStatus": src_status,
            "srcPortSpeed":  speed,
            "tgtDevice":     tdev,
            "tgtIfName":     tp,
            "tgtPortStatus": tgt_status,
            "tgtPortSpeed":  speed,
            "is_missing":    "no",
        })
        next_link_id += 1
        actual_keys.add(edge_key(sdev, sp, tdev, tp))
        speed_for_link[edge_key(sdev, sp, tdev, tp)] = speed

    # Compare against DOT to flag missing / unexpected
    dot_keys = set()
    for a, ap, b, bp in dot_edges:
        ap_n = port_name(ap)
        bp_n = port_name(bp)
        dot_keys.add(edge_key(a, ap_n, b, bp_n))

    # is_missing == "fail": actual exists but not in DOT
    for link in links:
        k = edge_key(link["srcDevice"], link["srcIfName"],
                     link["tgtDevice"], link["tgtIfName"])
        if k not in dot_keys:
            link["is_missing"] = "fail"

    # is_missing == "yes": DOT exists but no actual link
    for a, ap, b, bp in dot_edges:
        ap_n, bp_n = port_name(ap), port_name(bp)
        k = edge_key(a, ap_n, b, bp_n)
        if k in actual_keys:
            continue
        # Add both endpoints if they don't have nodes
        ensure_node(a)
        ensure_node(b)
        links.append({
            "id":            next_link_id,
            "source":        node_id_by_name[a],
            "target":        node_id_by_name[b],
            "srcDevice":     a,
            "srcIfName":     ap_n,
            "srcPortStatus": "DOWN",
            "srcPortSpeed":  "N/A",
            "tgtDevice":     b,
            "tgtIfName":     bp_n,
            "tgtPortStatus": "DOWN",
            "tgtPortSpeed":  "N/A",
            "is_missing":    "yes",
        })
        next_link_id += 1

    # Mark assets-known devices that have NO actual link AND no DOT entry
    # as "unknown" (offline / unreachable) so the icon turns greyed.
    reachable = set()
    for L in links:
        if L["is_missing"] != "yes":
            reachable.add(L["srcDevice"])
            reachable.add(L["tgtDevice"])
    host_only = host_names | set(
        n["name"] for n in nodes if n["icon"] in ("host", "server")
    )
    for n in nodes:
        if (n["name"] in device_info
                and n["name"] not in reachable
                and n["name"] not in host_only
                and n["icon"] not in ("host", "server", "firewall", "router")):
            n["icon"] = "unknown"

    return {
        "nodes": nodes,
        "links": links,
        "timestamp": datetime.now().strftime("%Y-%m-%d %H:%M"),
    }


# ---------- driver ----------

def main():
    ap = argparse.ArgumentParser(description="LLDPq-IB topology.js generator")
    ap.add_argument("--lldpq-dir", default=".",
                    help="Directory containing assets.ini, devices.yaml, topology.dot, "
                         "topology_config.yaml, monitor-results/ (default: cwd)")
    ap.add_argument("--web-root", default="/var/www/html",
                    help="Web root where the output topology.js will be written "
                         "(default: /var/www/html)")
    ap.add_argument("--output",
                    help="Override output path (default: <web-root>/topology/topology.js)")
    args = ap.parse_args()

    lldpq_dir = os.path.abspath(args.lldpq_dir)
    web_root  = os.path.abspath(args.web_root)
    output    = args.output or os.path.join(web_root, "topology", "topology.js")

    assets_path        = os.path.join(lldpq_dir, "assets.ini")
    # ib-assets.sh might write assets.ini to web root only -- check both
    if not os.path.exists(assets_path):
        alt = os.path.join(web_root, "assets.ini")
        if os.path.exists(alt):
            assets_path = alt
    devices_yaml_path  = os.path.join(lldpq_dir, "devices.yaml")
    ib_topology_path   = os.path.join(lldpq_dir, "monitor-results", "ib_topology.json")
    link_errors_path   = os.path.join(lldpq_dir, "monitor-results", "ib_link_errors.json")
    dot_path           = os.path.join(lldpq_dir, "topology.dot")
    if not os.path.exists(dot_path):
        alt = os.path.join(web_root, "topology.dot")
        if os.path.exists(alt):
            dot_path = alt
    config_path        = os.path.join(lldpq_dir, "topology_config.yaml")
    if not os.path.exists(config_path):
        alt = os.path.join(web_root, "topology_config.yaml")
        if os.path.exists(alt):
            config_path = alt

    topo = build_topology(
        assets_path, devices_yaml_path, ib_topology_path,
        link_errors_path, dot_path, config_path,
    )

    os.makedirs(os.path.dirname(output), exist_ok=True)
    with open(output, "w") as f:
        f.write("var topologyData = ")
        json.dump(topo, f, indent=2)
        f.write(";\n")

    print(f"Wrote {len(topo['nodes'])} nodes + {len(topo['links'])} links -> {output}")


if __name__ == "__main__":
    main()
