#!/usr/bin/env bash
# ib-local-scan.sh - Direct in-container IB fabric scan via local ibutils.
#
# The LLDPq-IB container runs --privileged --network host on an IB-connected node,
# so it has DIRECT UMAD access to the fabric. The standard ibutils
# (ibnetdiscover / iblinkinfo / sminfo / ibqueryerrors) are already in the image,
# but UMAD devices (/dev/infiniband/umad*) are root-only, so this script runs as
# root (via sudo from the diag-api CGI) and emits a compact JSON summary that the
# Diagnostics page renders. Output stays light (KB), unlike ibdiagnet's GB dumps.
#
# This is the cheap, on-demand, fabric-wide health source that does NOT need
# switch SSH (switches are CLI-only) or the full ibdiagnet bundle. Notably
# ibqueryerrors surfaces REAL per-port error counters (LinkDowned, SymbolErrors,
# PortXmitDiscards, ...) that the UFM REST API does not expose.
#
# Copyright (c) 2024-2026 LLDPq Project - Licensed under MIT License

set -uo pipefail

WEB_ROOT="${WEB_ROOT:-/var/www/html}"
MR="$WEB_ROOT/monitor-results"
OUTDIR="$MR/local-scan"
OUT_JSON="$MR/ib_fabric_scan.json"
LLDPQ_USER="${LLDPQ_USER:-lldpq}"
TMO="${IB_SCAN_TIMEOUT:-15}"
mkdir -p "$OUTDIR"

timeout "$TMO" ibnetdiscover     2>/dev/null > "$OUTDIR/ibnetdiscover.txt" || true
timeout "$TMO" iblinkinfo --line 2>/dev/null > "$OUTDIR/iblinkinfo.txt"   || true
timeout "$TMO" sminfo            2>/dev/null > "$OUTDIR/sminfo.txt"       || true
timeout "$TMO" ibqueryerrors     2>/dev/null > "$OUTDIR/ibqueryerrors.txt" || true

python3 - "$OUTDIR" "$OUT_JSON" <<'PY'
import json, os, re, sys
from datetime import datetime, timezone

outdir, outjson = sys.argv[1], sys.argv[2]
def rd(n):
    try:
        return open(os.path.join(outdir, n), errors="replace").read()
    except Exception:
        return ""

nd  = rd("ibnetdiscover.txt")
lli = rd("iblinkinfo.txt")
smi = rd("sminfo.txt")
qe  = rd("ibqueryerrors.txt")

switches = len(re.findall(r'^Switch\b', nd, re.M))
cas      = len(re.findall(r'^Ca\b', nd, re.M))

# iblinkinfo --line: one row per port. Count only CABLED links (a real peer name
# after ==>); empty cages / uncabled ports ("Polling", peer "") are normal and
# excluded. A cabled link that is not Active is flagged down/degraded.
links = 0
down_links = []
for ln in lli.splitlines():
    if '==>' not in ln:
        continue
    after = ln.split('==>', 1)[1]
    peers = re.findall(r'"([^"]*)"', after)
    peer = peers[-1] if peers else ''
    if not peer:
        continue  # uncabled port / empty cage -- not a real link
    links += 1
    m = re.search(r'==\(([^)]*)\)==>', ln)
    state = m.group(1) if m else ''
    if 'Active' not in state:
        down_links.append(ln.strip())

# sminfo: first non-empty line (e.g. "sminfo: sm lid 2 ... SMINFO_MASTER")
sm = next((ln.strip() for ln in smi.splitlines() if ln.strip()), "")

# ibqueryerrors blocks:
#   Errors for 0x<guid> "<desc>"
#      GUID 0x<guid> port <N|ALL>: [Counter == X (...)] [Counter2 == Y]
def clean_desc(d):
    # "MF0;nvis-ib-comp-leaf-02:MQM9700/U1" -> "nvis-ib-comp-leaf-02"
    if ';' in d:
        d = d.split(';', 1)[1]
    if ':' in d:
        d = d.split(':', 1)[0]
    return d.strip()

cur_desc = ""
err_ports = []
for ln in qe.splitlines():
    h = re.match(r'\s*Errors for\s+(\S+)\s+"(.*)"', ln)
    if h:
        cur_desc = clean_desc(h.group(2))
        continue
    p = re.match(r'\s*GUID\s+(\S+)\s+port\s+(\S+):\s*(.*)', ln)
    if p:
        counters = {k: int(v) for k, v in re.findall(r'\[(\w+)\s*==\s*(\d+)', p.group(3))}
        counters = {k: v for k, v in counters.items() if v > 0}
        if counters:
            err_ports.append({
                "device": cur_desc,
                "guid": p.group(1),
                "port": p.group(2),
                "counters": counters,
            })

gen_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
mr_dir = os.path.dirname(outjson)

# --- Feed REAL per-port error counters into ib_link_errors.json as DELTAS -----
# ibqueryerrors reports cumulative counters (a 200-day-up switch has huge totals
# that are not current faults). We diff against the previous baseline so the Link
# Errors page shows only ACTIVELY incrementing counters. First run = baseline only.
state_path = os.path.join(mr_dir, "ib_counter_state.json")
try:
    prev = (json.load(open(state_path)) or {}).get("ports", {})
except Exception:
    prev = {}
first_run = not prev

def severity_of(d):
    ld = d.get("LinkDownedCounter", 0); se = d.get("SymbolErrorCounter", 0)
    rcv = d.get("PortRcvErrors", 0); ler = d.get("LinkErrorRecoveryCounter", 0)
    xd = d.get("PortXmitDiscards", 0)
    if ld >= 5 or se >= 1000:
        return "critical"
    if ld > 0 or se > 0 or rcv > 0 or ler > 0 or xd >= 100:
        return "warning"
    return None

new_state = {}
problem_ports = []
for e in err_ports:
    if e["port"] == "ALL":
        continue  # node aggregate row, not a per-port sample
    key = f'{e["guid"]}:{e["port"]}'
    cur = e["counters"]
    new_state[key] = cur
    if first_run or key not in prev:
        continue  # establish baseline; don't flag pre-existing cumulative errors
    delta = {c: cur[c] - prev[key].get(c, 0) for c in cur if cur[c] - prev[key].get(c, 0) > 0}
    if not delta:
        continue
    sev = severity_of(delta)
    if not sev:
        continue
    problem_ports.append({
        "device": e["device"], "port": e["port"], "guid": e["guid"],
        "severity": sev, "delta": delta,
        "flaps_1h": delta.get("LinkDownedCounter", 0), "flaps_24h": 0,
        "note": "live ibqueryerrors delta",
    })

crit = sum(1 for p in problem_ports if p["severity"] == "critical")
warn = sum(1 for p in problem_ports if p["severity"] == "warning")
flapping = sum(1 for p in problem_ports if p.get("flaps_1h", 0) > 0)
link_errors = {
    "generated_at": gen_at, "last_update": gen_at,
    "source": "container-local-ibutils",
    "total_ports_monitored": links,
    "problem_ports": problem_ports,
    "summary": {
        "critical_count": crit, "warning_count": warn,
        "critical": crit, "warning": warn,
        "flapping_1h": flapping, "total_ports": links,
        "first_baseline": first_run,
    },
}
try:
    json.dump(link_errors, open(os.path.join(mr_dir, "ib_link_errors.json"), "w"), indent=2)
    json.dump({"generated_at": gen_at, "ports": new_state}, open(state_path, "w"), indent=2)
except Exception:
    pass

out = {
    "success": True,
    "generated_at": gen_at,
    "source": "container-local-ibutils",
    "summary": {
        "switches": switches,
        "cas": cas,
        "links": links,
        "down_links": len(down_links),
        "ports_with_errors": len([e for e in err_ports if e["port"] != "ALL"]),
        "active_error_ports": len(problem_ports),
        "baseline": first_run,
        "sm": sm,
    },
    "sm_info": sm,
    "down_links_list": down_links[:100],
    "error_ports": err_ports[:300],
}
json.dump(out, open(outjson, "w"), indent=2)
print(json.dumps(out))
PY

chown -R "$LLDPQ_USER:www-data" "$OUTDIR" "$OUT_JSON" 2>/dev/null || true
