#!/usr/bin/env python3
"""ufm-adapter.py - Populate LLDPq-IB JSON from the UFM REST API (UFM-backed mode).

For NDR + UFM fabrics the switches run CLI-only admin accounts (no SSH shell, no
`ib <util>` prefix) and the Subnet Manager runs on the UFM appliance, not on the
switches. So the authoritative data source is UFM's REST API, not per-switch SSH.

This adapter pulls UFM inventory / links / ports / pkeys / modules and emits the
SAME `monitor-results/*.json` files that the existing LLDPq-IB pages already
consume, so the whole UI lights up with real fabric data without any switch SSH.

It complements (does not replace) `ib-hw-collect.sh`, which adds switch-local
hardware (power/fan/temperature/inventory) via enable-mode interactive SSH.

Connection settings are read from /etc/lldpq.conf (UFM_URL, UFM_USERNAME,
UFM_PASSWORD, UFM_TOKEN, UFM_VERIFY_TLS) and can be overridden by env or CLI.

Usage:
    ufm-adapter.py [--results-dir DIR] [--web-root DIR]
                   [--ufm-url URL] [--user U] [--password P]

Copyright (c) 2024-2026 LLDPq Project - Licensed under MIT License
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timezone

try:
    import requests
    from requests.auth import HTTPBasicAuth
    requests.packages.urllib3.disable_warnings()  # type: ignore
except Exception:  # pragma: no cover
    requests = None


# ---------------------------------------------------------------------------
# config / helpers
# ---------------------------------------------------------------------------
def load_conf(path="/etc/lldpq.conf"):
    conf = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, _, v = line.partition("=")
                conf[k.strip()] = v.strip().strip('"').strip("'")
    except Exception:
        pass
    return conf


def now_iso():
    return datetime.now(timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")


def norm_guid(g):
    """LLDPq stores GUIDs as 0x-prefixed; UFM returns bare hex."""
    if not g:
        return ""
    g = str(g).strip()
    return g if g.lower().startswith("0x") else "0x" + g


def host_of(desc, fallback=""):
    """node_description 'host:port/dname' -> 'host'. HCAs may have a space form."""
    if not desc:
        return fallback
    return str(desc).split(":")[0].strip() or fallback


def role_map(ufm_role, is_switch):
    """Map UFM roles to LLDPq roles (spine/leaf/core/host)."""
    r = (ufm_role or "").lower()
    if not is_switch:
        return "host"
    if r in ("core", "spine", "superspine"):
        return "spine"
    if r in ("tor", "leaf", "access"):
        return "leaf"
    return r or "switch"


class Ufm:
    def __init__(self, url, user, password, token="", verify=False):
        self.base = url.rstrip("/")
        self.user = user
        self.password = password
        self.token = token
        self.verify = verify
        if requests is None:
            raise RuntimeError("python3 'requests' module is required")
        self.s = requests.Session()
        self.s.verify = verify
        if token:
            self.s.headers.update({"Authorization": f"Basic {token}"})
        else:
            self.s.auth = HTTPBasicAuth(user, password)

    def get(self, ep):
        for prefix in ("/ufmRest", "/ufmRestV3"):
            try:
                r = self.s.get(f"{self.base}{prefix}/{ep}", timeout=40)
                if r.status_code == 200:
                    return r.json()
            except Exception:
                continue
        return None


# ---------------------------------------------------------------------------
# builders (one per output JSON; each maps UFM -> LLDPq schema)
# ---------------------------------------------------------------------------
def build_indexes(systems, ports):
    """Return guid->{type,role,model,hostname,ip,serial,fw,uptime} and guid->lid."""
    by_guid = {}
    for s in systems or []:
        g = norm_guid(s.get("guid") or s.get("system_guid"))
        if not g:
            continue
        is_sw = "switch" in (str(s.get("type", "")) + str(s.get("technology", ""))).lower()
        by_guid[g] = {
            "type": "switch" if is_sw else "hca",
            "role": role_map(s.get("role"), is_sw),
            "model": s.get("model") or "",
            "hostname": s.get("system_name") or s.get("name") or "",
            "ip": s.get("ip") or "",
            "serial": s.get("serial_number") or s.get("sys_sn") or "",
            "fw": s.get("fw_version") or s.get("sw_version") or "",
            "uptime": s.get("uptime") or "",
            "technology": s.get("technology") or "",
        }
    lid_by_guid = {}
    for p in ports or []:
        pg = norm_guid(p.get("peer_node_guid") or p.get("peer_guid"))
        plid = p.get("peer_lid")
        if pg and plid not in (None, "", "N/A"):
            try:
                lid_by_guid[pg] = int(plid)
            except Exception:
                pass
    return by_guid, lid_by_guid


def fabric_tech(by_guid):
    for v in by_guid.values():
        if v["type"] == "switch" and v.get("technology"):
            return v["technology"]
    return ""


def build_topology(links, by_guid, lid_by_guid):
    tech = fabric_tech(by_guid)
    out_links = []
    node_desc = {}     # guid -> description (hostname form)
    speed_dist = {}

    for l in links or []:
        sg = norm_guid(l.get("source_guid"))
        tg = norm_guid(l.get("destination_guid"))
        if not sg or not tg:
            continue
        sdesc = host_of(l.get("source_port_node_description"), by_guid.get(sg, {}).get("hostname", sg))
        tdesc = host_of(l.get("destination_port_node_description"), by_guid.get(tg, {}).get("hostname", tg))
        node_desc.setdefault(sg, sdesc)
        node_desc.setdefault(tg, tdesc)
        width = l.get("width") or ""
        speed = (f"{width}{tech}" if width else tech) or "unknown"
        speed_dist[speed] = speed_dist.get(speed, 0) + 1
        out_links.append({
            "source_guid": sg,
            "source_port": _int(l.get("source_port")),
            "source_type": by_guid.get(sg, {}).get("type", "switch"),
            "source_desc": sdesc,
            "target_guid": tg,
            "target_port": _int(l.get("destination_port")),
            "target_type": by_guid.get(tg, {}).get("type", "hca"),
            "target_desc": tdesc,
            "speed": speed,
            "discovered_from": sdesc,
        })

    # Nodes: every switch in inventory + every endpoint that appears in links.
    guids = set(node_desc) | {g for g, v in by_guid.items() if v["type"] == "switch"}
    nodes = []
    for g in sorted(guids):
        meta = by_guid.get(g, {})
        desc = node_desc.get(g) or meta.get("hostname") or g
        ntype = meta.get("type") or ("switch" if g in by_guid else "hca")
        nodes.append({
            "description": desc,
            "type": ntype,
            "guid": g,
            "lid": lid_by_guid.get(g, 0),
            "hostname": meta.get("hostname") or desc,
            "role": meta.get("role") or ("host" if ntype == "hca" else "switch"),
            "model": meta.get("model") or "",
        })

    switches = sum(1 for n in nodes if n["type"] == "switch")
    hcas = sum(1 for n in nodes if n["type"] == "hca")
    return {
        "generated_at": now_iso(),
        "source": "ufm",
        "nodes": nodes,
        "links": out_links,
        "summary": {
            "total_nodes": len(nodes),
            "total_links": len(out_links),
            "switches": switches,
            "hcas": hcas,
            "routers": 0,
            "orphan_count": 0,
            "speed_distribution": speed_dist,
        },
    }


def build_sm_status(by_guid, ufm_version, ufm_host):
    """SM runs on the UFM appliance for these fabrics; synthesize a Master entry.
    If any switch advertises an SM mode, surface those too."""
    sms = []
    opensm = (ufm_version or {}).get("opensm", "")
    sms.append({
        "guid": "ufm-sm",
        "hostname": f"UFM SM ({ufm_host})" if ufm_host else "UFM Subnet Manager",
        "state": "Master",
        "priority": 0,
        "lid": 0,
        "opensm": opensm,
    })
    return {
        "generated_at": now_iso(),
        "source": "ufm",
        "master_guid": "ufm-sm",
        "master_hostname": sms[0]["hostname"],
        "opensm_version": opensm,
        "last_sweep_seconds": None,
        "sms": sms,
        "disagreements": [],
        "summary": {
            "total_sms": len(sms),
            "master_count": 1,
            "standby_count": 0,
            "has_master": True,
            "has_redundancy": False,
            "disagreement_count": 0,
        },
    }


def build_link_errors(links, ports):
    """Derive problem ports from UFM's own link severity + non-Active port state."""
    SEV = {"critical": "critical", "minor": "warning", "warning": "warning"}
    problems = []
    total = len(links or [])
    for l in links or []:
        sev = SEV.get(str(l.get("severity", "")).lower())
        if not sev:
            continue
        problems.append({
            "device": host_of(l.get("source_port_node_description"), norm_guid(l.get("source_guid"))),
            "port": f"IB1/{_int(l.get('source_port'))}",
            "peer": host_of(l.get("destination_port_node_description"), ""),
            "severity": sev,
            "symbol_errors": 0,
            "link_downed": 0,
            "rcv_errors": 0,
            "xmit_discards": 0,
            "first_seen": now_iso(),
            "note": f"UFM link severity: {l.get('severity')}",
        })
    # Cabled-but-down ports reported as warnings. Empty cages (no peer) are
    # normal and must NOT be flagged, or the page floods with false positives.
    for p in ports or []:
        peer = str(p.get("peer_node_guid") or p.get("peer_guid") or "").strip()
        state = str(p.get("logical_state", "")).lower()
        if peer and peer.upper() != "N/A" and state and state not in ("active", "n/a"):
            problems.append({
                "device": host_of(p.get("peer_node_description"), ""),
                "port": p.get("peer_port_dname") or p.get("name") or "",
                "peer": p.get("peer_node_name") or "",
                "severity": "warning",
                "symbol_errors": 0, "link_downed": 0, "rcv_errors": 0, "xmit_discards": 0,
                "first_seen": now_iso(),
                "note": f"Port logical_state={p.get('logical_state')}",
            })
    crit = sum(1 for p in problems if p["severity"] == "critical")
    warn = sum(1 for p in problems if p["severity"] == "warning")
    return {
        "generated_at": now_iso(),
        "source": "ufm",
        "problem_ports": problems,
        "summary": {
            "total_ports": total,
            "healthy": max(0, total - len(problems)),
            "critical": crit,
            "warning": warn,
            "flapping": 0,
            "critical_count": crit,
            "warning_count": warn,
            "flapping_1h": 0,
        },
    }


def build_pkey(ufm, pkey_list, by_guid):
    switches = [v["hostname"] for v in by_guid.values() if v["type"] == "switch" and v["hostname"]]
    rows = []
    for key in (pkey_list or []):
        detail = ufm.get(f"resources/pkeys/{key}") or {}
        members = detail.get("guids") or detail.get("members") or []
        rows.append({
            "pkey": key,
            "names": [detail.get("name", "")] if detail.get("name") else [],
            "devices": switches,
            "device_count": len(switches),
            "mtus": [str(detail.get("mtu"))] if detail.get("mtu") else [],
            "rates": [str(detail.get("rate"))] if detail.get("rate") else [],
            "ipoib_states": [str(detail.get("ip_over_ib"))] if "ip_over_ib" in detail else [],
            "max_members": len(members) if isinstance(members, list) else 0,
            "consistent": True,
            "policy_status": "n/a",
            "policy_notes": [],
        })
    return {
        "generated_at": now_iso(),
        "source": "ufm",
        "pkeys": rows,
        "per_device": {h: [{"pkey": r["pkey"]} for r in rows] for h in switches},
        "policy": {"enabled": False, "violations": [],
                   "summary": {"expected": 0, "pass": 0, "warning": 0, "missing": 0, "unexpected": 0}},
        "summary": {
            "total_pkeys": len(rows),
            "partition_count": len(rows),
            "devices_polled": len(switches),
            "inconsistencies": 0,
            "inconsistency_count": 0,
            "policy_violations": 0,
        },
    }


def build_sharp(modules, by_guid):
    sharp_nodes = [m for m in (modules or []) if str(m.get("type", "")).upper() == "SHARP"]
    nodes = []
    for m in sharp_nodes:
        nodes.append({
            "hostname": m.get("device_name") or "",
            "guid": norm_guid(m.get("hosting_system_guid") or m.get("name")),
            "role": "aggregator",
            "status": m.get("status", ""),
        })
    return {
        "generated_at": now_iso(),
        "source": "ufm",
        "enabled": bool(sharp_nodes),
        "version": "",
        "nodes": nodes,
        "trees": [],
        "summary": {
            "node_count": len(nodes),
            "total_aggregation_nodes": len(nodes),
            "tree_count": 0,
            "devices_with_sharp": len(nodes),
        },
    }


def build_assets_ini(by_guid, identity=None):
    """assets.ini from UFM inventory, enriched with switch-local identity
    (serial / MLNX-OS release / uptime) collected by ib-hw-collect.sh when
    present -- UFM only knows the ASIC firmware, not the MLNX-OS release."""
    identity = identity or {}
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
    lines = [
        f"# LLDPq-IB Assets - {ts}",
        "# DEVICE-NAME\tIP\tMODEL\tSERIAL\tRELEASE\tOS\tUPTIME",
    ]
    for v in sorted((x for x in by_guid.values() if x["type"] == "switch"),
                    key=lambda x: x["hostname"]):
        if not v["hostname"]:
            continue
        ident = identity.get(v["hostname"], {})
        model = v["model"] or ident.get("model") or "-"
        serial = ident.get("serial") or v["serial"] or "-"
        release = ident.get("release") or v["fw"] or "-"
        uptime = ident.get("uptime") or v["uptime"] or "-"
        lines.append("\t".join([
            v["hostname"], v["ip"] or "-", model, serial, release, "MLNX-OS", uptime,
        ]))
    return "\n".join(lines) + "\n"


def _int(x):
    try:
        return int(x)
    except Exception:
        return x if x is not None else 0


# ---------------------------------------------------------------------------
# driver
# ---------------------------------------------------------------------------
def main():
    conf = load_conf()
    ap = argparse.ArgumentParser(description="UFM -> LLDPq-IB JSON adapter")
    ap.add_argument("--results-dir", default=conf.get("LLDPQ_DIR", "/home/lldpq/lldpq") + "/monitor-results")
    ap.add_argument("--web-root", default=conf.get("WEB_ROOT", "/var/www/html"))
    ap.add_argument("--ufm-url", default=os.environ.get("UFM_URL", conf.get("UFM_URL", "")))
    ap.add_argument("--user", default=os.environ.get("UFM_USERNAME", conf.get("UFM_USERNAME", "admin")))
    ap.add_argument("--password", default=os.environ.get("UFM_PASSWORD", conf.get("UFM_PASSWORD", "")))
    ap.add_argument("--token", default=os.environ.get("UFM_TOKEN", conf.get("UFM_TOKEN", "")))
    args = ap.parse_args()

    if not args.ufm_url:
        sys.stderr.write("ERROR: UFM_URL not set (env, /etc/lldpq.conf, or --ufm-url)\n")
        return 2

    verify = str(conf.get("UFM_VERIFY_TLS", "false")).lower() in ("1", "true", "yes")
    try:
        ufm = Ufm(args.ufm_url, args.user, args.password, args.token, verify)
    except Exception as e:
        sys.stderr.write(f"ERROR: {e}\n")
        return 2

    ver = ufm.get("app/ufm_version")
    if ver is None:
        sys.stderr.write(f"ERROR: cannot reach UFM at {args.ufm_url} (auth/url?)\n")
        return 1

    systems = ufm.get("resources/systems") or []
    links = ufm.get("resources/links") or []
    ports = ufm.get("resources/ports") or []
    pkeys = ufm.get("resources/pkeys") or []
    modules = ufm.get("resources/modules") or []

    by_guid, lid_by_guid = build_indexes(systems, ports)
    ufm_host = args.ufm_url.split("//")[-1].split("/")[0]

    bundles = {
        "ib_topology.json": build_topology(links, by_guid, lid_by_guid),
        "ib_sm_status.json": build_sm_status(by_guid, ver, ufm_host),
        "ib_link_errors.json": build_link_errors(links, ports),
        "ib_pkey.json": build_pkey(ufm, pkeys, by_guid),
        "ib_sharp_status.json": build_sharp(modules, by_guid),
    }

    results = args.results_dir
    os.makedirs(results, exist_ok=True)
    for name, data in bundles.items():
        with open(os.path.join(results, name), "w") as f:
            json.dump(data, f, indent=2)

    # assets.ini lives in the web root (assets.html reads /assets.ini).
    # Enrich with switch-local identity from ib-hw-collect.sh if available.
    identity = {}
    try:
        with open(os.path.join(results, "switch_identity.json")) as f:
            identity = (json.load(f) or {}).get("switches", {})
    except Exception:
        identity = {}
    assets = build_assets_ini(by_guid, identity)
    for d in (results, args.web_root):
        try:
            with open(os.path.join(d, "assets.ini"), "w") as f:
                f.write(assets)
        except Exception:
            pass

    # mirror JSON to the web root's monitor-results so the UI can read them
    web_mr = os.path.join(args.web_root, "monitor-results")
    if os.path.abspath(web_mr) != os.path.abspath(results):
        os.makedirs(web_mr, exist_ok=True)
        for name in bundles:
            try:
                with open(os.path.join(results, name)) as src, open(os.path.join(web_mr, name), "w") as dst:
                    dst.write(src.read())
            except Exception:
                pass

    topo = bundles["ib_topology.json"]["summary"]
    le = bundles["ib_link_errors.json"]["summary"]
    print(f"UFM adapter OK: {topo['switches']} switches, {topo['hcas']} HCAs, "
          f"{topo['total_links']} links, {le['critical']} critical / {le['warning']} warning ports, "
          f"{len(pkeys)} pkeys")
    return 0


if __name__ == "__main__":
    sys.exit(main())
