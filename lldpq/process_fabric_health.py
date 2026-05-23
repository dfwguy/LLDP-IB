#!/usr/bin/env python3
"""Compute a single LLDPq-IB fabric health score.

Inputs are existing monitor-results JSON files. Output:
  monitor-results/fabric_health.json

The score is intentionally transparent: each component starts at 100 and
deducts points for concrete, operator-actionable findings.
"""

from __future__ import annotations

import json
import os
from datetime import datetime, timezone


def load(base: str, name: str):
    path = os.path.join(base, name)
    if not os.path.exists(path):
        return None
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return None


def clamp(n: int) -> int:
    return max(0, min(100, int(round(n))))


def main(base: str = "monitor-results") -> int:
    sm = load(base, "ib_sm_status.json") or {}
    links = load(base, "ib_link_errors.json") or {}
    pkey = load(base, "ib_pkey.json") or {}
    tr = load(base, "transceiver_inventory.json") or {}
    logs = load(base, "log_summary.json") or {}
    topo = load(base, "ib_topology.json") or {}

    findings = []

    # SM score
    sm_s = sm.get("summary", {})
    sm_score = 100
    if not sm_s.get("has_master", False):
        sm_score -= 60
        findings.append({"severity": "critical", "component": "sm", "message": "No Master SM detected"})
    if sm_s.get("master_count", 0) > 1:
        sm_score -= 40
        findings.append({"severity": "critical", "component": "sm", "message": "Multiple Master SMs detected"})
    if not sm_s.get("has_redundancy", False):
        sm_score -= 12
        findings.append({"severity": "warning", "component": "sm", "message": "No standby SM detected"})
    disagreements = len(sm.get("disagreements") or [])
    if disagreements:
        sm_score -= min(20, disagreements * 8)
        findings.append({"severity": "warning", "component": "sm", "message": f"{disagreements} SM disagreement(s)"})

    # Link score
    l_s = links.get("summary", {})
    crit = int(l_s.get("critical", l_s.get("critical_count", 0)) or 0)
    warn = int(l_s.get("warning", l_s.get("warning_count", 0)) or 0)
    flap = int(l_s.get("flapping", l_s.get("flapping_1h", 0)) or 0)
    link_score = 100 - min(45, crit * 14) - min(25, warn * 5) - min(15, flap * 3)
    if crit:
        findings.append({"severity": "critical", "component": "links", "message": f"{crit} critical link-error port(s)"})
    if warn:
        findings.append({"severity": "warning", "component": "links", "message": f"{warn} warning link-error port(s)"})
    if flap:
        findings.append({"severity": "warning", "component": "links", "message": f"{flap} flapping port(s) in the last hour"})

    # P_Key / policy score
    p_s = pkey.get("summary", {})
    inconsist = int(p_s.get("inconsistencies", p_s.get("inconsistency_count", 0)) or 0)
    policy = pkey.get("policy") or {}
    policy_summary = policy.get("summary") or {}
    missing = int(policy_summary.get("missing", 0) or 0)
    policy_warn = int(policy_summary.get("warning", 0) or 0)
    unexpected = int(policy_summary.get("unexpected", 0) or 0)
    pkey_score = 100 - min(30, inconsist * 12) - min(35, missing * 15) - min(20, policy_warn * 8) - min(8, unexpected * 2)
    if inconsist:
        findings.append({"severity": "warning", "component": "pkey", "message": f"{inconsist} P_Key consistency issue(s)"})
    if missing or policy_warn or unexpected:
        findings.append({"severity": "warning", "component": "pkey", "message": f"P_Key policy findings: missing={missing}, warning={policy_warn}, unexpected={unexpected}"})

    # Transceiver score
    t_s = tr.get("summary", {})
    mixed = t_s.get("mixed_fw_models") or []
    status_counts = t_s.get("status_counts") or {}
    non_ok = sum(v for k, v in status_counts.items() if str(k).lower() not in ("ok", "normal", "good"))
    trans_score = 100 - min(20, len(mixed) * 8) - min(35, non_ok * 5)
    if mixed:
        findings.append({"severity": "warning", "component": "transceiver", "message": f"Mixed firmware models: {', '.join(mixed)}"})
    if non_ok:
        findings.append({"severity": "warning", "component": "transceiver", "message": f"{non_ok} non-OK transceiver module(s)"})

    # Logs score
    log_score = 100
    log_score -= min(40, int(logs.get("critical", 0) or 0) * 15)
    log_score -= min(20, int(logs.get("error", 0) or 0) * 3)
    log_score -= min(10, int(logs.get("warning", 0) or 0))
    if logs.get("critical", 0):
        findings.append({"severity": "critical", "component": "logs", "message": f"{logs.get('critical')} critical log entries"})
    elif logs.get("error", 0):
        findings.append({"severity": "warning", "component": "logs", "message": f"{logs.get('error')} error log entries"})

    # Topology wiring score (pure topology presence; detailed wiring is start.html/lldp.html)
    topology_score = 100
    topo_summary = topo.get("summary") or {}
    if not topo_summary.get("total_nodes"):
        topology_score -= 60
        findings.append({"severity": "critical", "component": "topology", "message": "No topology nodes discovered"})
    if topo_summary.get("orphan_count", 0):
        topology_score -= min(20, topo_summary.get("orphan_count", 0) * 4)
        findings.append({"severity": "warning", "component": "topology", "message": f"{topo_summary.get('orphan_count')} orphan topology node(s)"})

    components = {
        "sm": clamp(sm_score),
        "links": clamp(link_score),
        "pkey": clamp(pkey_score),
        "transceiver": clamp(trans_score),
        "logs": clamp(log_score),
        "topology": clamp(topology_score),
    }
    weights = {"sm": 0.24, "links": 0.24, "pkey": 0.14, "transceiver": 0.14, "logs": 0.10, "topology": 0.14}
    score = clamp(sum(components[k] * weights[k] for k in weights))
    grade = "excellent" if score >= 90 else "good" if score >= 75 else "warning" if score >= 55 else "critical"

    out = {
        "last_update": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "score": score,
        "grade": grade,
        "components": components,
        "findings": findings[:20],
        "weights": weights,
    }
    os.makedirs(base, exist_ok=True)
    with open(os.path.join(base, "fabric_health.json"), "w") as f:
        json.dump(out, f, indent=2)
    print(f"Fabric health: {score}/100 ({grade})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
