#!/bin/bash
# ai-api.sh - AI Assistant API
# Backend for ai.html — LLM proxy with fabric context
# Called by nginx fcgiwrap

# Load config
if [[ -f /etc/lldpq.conf ]]; then
    source /etc/lldpq.conf
fi

LLDPQ_DIR="${LLDPQ_DIR:-/home/lldpq/lldpq}"
LLDPQ_USER="${LLDPQ_USER:-lldpq}"
WEB_ROOT="${WEB_ROOT:-/var/www/html}"

# AI config
# AI is DISABLED by default in the IB edition: the operator opts in by
# setting AI_PROVIDER + AI_MODEL (+ AI_API_KEY for cloud providers, or
# OLLAMA_URL for a local Ollama). Until then the chat UI returns a clear
# "AI provider not configured" message instead of guessing.
AI_PROVIDER="${AI_PROVIDER:-}"
AI_MODEL="${AI_MODEL:-}"
AI_API_KEY="${AI_API_KEY:-}"
AI_API_URL="${AI_API_URL:-https://api.openai.com/v1}"
OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"
AI_PROXY_URL="${AI_PROXY_URL:-}"

# Parse query string
ACTION=$(echo "$QUERY_STRING" | grep -oP 'action=\K[^&]*' | head -1)

source "$(dirname "$0")/auth-guard.sh"
case "$ACTION" in
    get-config|save-config|test-connection|list-models)
        require_admin ;;
    *)
        require_auth ;;
esac

# All responses are JSON (SSE streaming not supported by fcgiwrap)
echo "Content-Type: application/json"
echo ""

# Read POST data
POST_DATA=""
if [ "$REQUEST_METHOD" = "POST" ] && [ -n "$CONTENT_LENGTH" ] && [ "$CONTENT_LENGTH" -gt 0 ] 2>/dev/null; then
    POST_DATA=$(dd bs=4096 count=$(( (CONTENT_LENGTH + 4095) / 4096 )) 2>/dev/null | head -c "$CONTENT_LENGTH")
fi

# Export for Python
export LLDPQ_DIR LLDPQ_USER WEB_ROOT
export AI_PROVIDER AI_MODEL AI_API_KEY AI_API_URL OLLAMA_URL AI_PROXY_URL
export POST_DATA ACTION

python3 << 'PYTHON_SCRIPT'
import json
import sys
import os
import re
import time
import glob

ACTION = os.environ.get('ACTION', '')
POST_DATA = os.environ.get('POST_DATA', '')
LLDPQ_DIR = os.environ.get('LLDPQ_DIR', '/home/lldpq/lldpq')
LLDPQ_USER = os.environ.get('LLDPQ_USER', 'lldpq')
WEB_ROOT = os.environ.get('WEB_ROOT', '/var/www/html')
AI_PROVIDER = os.environ.get('AI_PROVIDER', '')
AI_MODEL = os.environ.get('AI_MODEL', '')
AI_API_KEY = os.environ.get('AI_API_KEY', '')
AI_API_URL = os.environ.get('AI_API_URL', 'https://api.openai.com/v1')
OLLAMA_URL = os.environ.get('OLLAMA_URL', 'http://localhost:11434')
AI_PROXY_URL = os.environ.get('AI_PROXY_URL', '')

# Set HTTP proxy if configured (allows airgapped servers to reach cloud APIs via SSH tunnel)
if AI_PROXY_URL:
    os.environ['http_proxy'] = AI_PROXY_URL
    os.environ['https_proxy'] = AI_PROXY_URL

ANALYSIS_FILE = os.path.join(WEB_ROOT, 'ai-analysis.json')

def result_json(data):
    print(json.dumps(data))
    sys.exit(0)

def error_json(msg):
    result_json({"success": False, "error": msg})

def sse_event(data, event=None):
    """Send a Server-Sent Event."""
    if event:
        sys.stdout.write(f"event: {event}\n")
    sys.stdout.write(f"data: {json.dumps(data)}\n\n")
    sys.stdout.flush()

# ======================== CONTEXT BUILDER (IB edition) ========================
# Reads the IB JSON outputs produced by `process_ib_*.py` and the local
# `assets.ini`. Everything is read-only; nothing is mutated.

MONITOR_RESULTS_DIR = os.path.join(LLDPQ_DIR, 'monitor-results')


def _load_json_safe(name):
    """Load <name> from monitor-results/, fall back to /var/www/html/monitor-results/."""
    for base in (MONITOR_RESULTS_DIR, os.path.join(WEB_ROOT, 'monitor-results')):
        p = os.path.join(base, name)
        if os.path.exists(p):
            try:
                with open(p) as f:
                    return json.load(f)
            except Exception:
                return None
    return None


def build_fabric_summary():
    """Compact IB fabric summary -- one line per system, plus headline
    counts the LLM can quote without hallucinating.

    Returns: (summary_text, devices_dict, device_health_dict)
    """
    summary = []

    # 1. Device inventory from devices.yaml
    devices = {}
    roles = {}
    try:
        devices_file = os.path.join(LLDPQ_DIR, 'devices.yaml')
        if os.path.exists(devices_file):
            import yaml
            with open(devices_file) as f:
                data = yaml.safe_load(f) or {}
            section = data.get('devices', data)
            if isinstance(section, dict):
                for ip, info in section.items():
                    if ip in ('defaults', 'endpoint_hosts'):
                        continue
                    if isinstance(info, str):
                        m = re.match(r'^(.+?)\s+@(\w+)$', info.strip())
                        hostname = m.group(1).strip() if m else info.strip()
                        role = m.group(2).lower() if m else 'unknown'
                    elif isinstance(info, dict):
                        hostname = info.get('hostname', str(ip))
                        role = info.get('role', 'unknown').lower()
                    else:
                        hostname = str(ip)
                        role = 'unknown'
                    devices[str(ip)] = {'hostname': hostname, 'role': role, 'ip': str(ip)}
                    roles[role] = roles.get(role, 0) + 1
    except Exception:
        pass

    role_summary = ', '.join(f"{count} {role}" for role, count in sorted(roles.items(), key=lambda x: -x[1]))
    summary.append(f"DEVICE INVENTORY: {len(devices)} devices ({role_summary or 'no roles declared'})")

    # 2. Reachability from assets.ini (last col 1=reachable)
    device_health = {}
    reachable = 0
    for base in (LLDPQ_DIR, WEB_ROOT):
        ai_path = os.path.join(base, 'assets.ini')
        if not os.path.exists(ai_path):
            continue
        try:
            with open(ai_path) as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith('#'):
                        continue
                    parts = line.split('\t')
                    if len(parts) >= 2:
                        host = parts[0]
                        status = parts[-1].strip()
                        device_health[host] = {
                            'ip':       parts[1] if len(parts) > 1 else '',
                            'model':    parts[2] if len(parts) > 2 else '',
                            'serial':   parts[3] if len(parts) > 3 else '',
                            'release':  parts[4] if len(parts) > 4 else '',
                            'status':   'ok' if status == '1' else 'unreachable',
                        }
                        if status == '1':
                            reachable += 1
            break
        except Exception:
            pass
    summary.append(f"REACHABILITY: {reachable}/{len(device_health)} switches/HCAs responding (assets.ini)")

    # 3. Subnet Manager
    sm = _load_json_safe('ib_sm_status.json')
    if sm:
        s = sm.get('summary', {})
        master_host = sm.get('master_hostname') or 'unknown'
        master_guid = sm.get('master_guid', '')
        sms = sm.get('sms', [])
        summary.append(
            f"SUBNET MANAGER: master={master_host} ({master_guid[:18] + '…' if len(master_guid) > 22 else master_guid}), "
            f"standby={s.get('standby_count', 0)}, "
            f"disagreements={s.get('disagreement_count', len(sm.get('disagreements', [])))}, "
            f"last_sweep={sm.get('last_sweep_seconds', '?')}s, "
            f"total_sms={len(sms)}"
        )
        for d in (sm.get('disagreements') or [])[:3]:
            summary.append(f"  SM DISAGREEMENT: {d.get('node', '?')} claimed {d.get('claimed_master', '?')[:18]}… vs actual {d.get('actual_master', '?')[:18]}…")

    # 4. Topology
    topo = _load_json_safe('ib_topology.json')
    if topo:
        s = topo.get('summary', {})
        speeds = ', '.join(f"{v}x {k}" for k, v in (s.get('speed_distribution') or {}).items())
        summary.append(
            f"TOPOLOGY: {s.get('total_nodes', 0)} nodes "
            f"({s.get('switches', 0)} switches, {s.get('hcas', 0)} HCAs, {s.get('routers', 0)} routers), "
            f"{s.get('total_links', 0)} links [{speeds or 'unknown speed'}]"
        )

    # 5. Link errors
    le = _load_json_safe('ib_link_errors.json')
    if le:
        s = le.get('summary', {})
        crit = s.get('critical', s.get('critical_count', 0))
        warn = s.get('warning', s.get('warning_count', 0))
        flap = s.get('flapping', s.get('flapping_1h', 0))
        summary.append(
            f"IB LINK HEALTH: {s.get('healthy', 0)}/{s.get('total_ports', 0)} healthy, "
            f"{crit} CRITICAL, {warn} WARNING, {flap} flapping in last 1h"
        )
        for p in (le.get('problem_ports') or [])[:5]:
            summary.append(
                f"  {p.get('severity', '?').upper()}: {p.get('device', '?')}:{p.get('port', '?')} "
                f"(peer={p.get('peer', '?')}) "
                f"symbol_err={p.get('symbol_errors', 0)} link_down={p.get('link_downed', 0)} "
                f"rcv_err={p.get('rcv_errors', 0)} -- {p.get('note', '')}"
            )

    # 6. P_Keys (IB partitions)
    pk = _load_json_safe('ib_pkey.json')
    if pk:
        s = pk.get('summary', {})
        partitions = pk.get('pkeys') or {}
        summary.append(
            f"P_KEYS: {s.get('partition_count', len(partitions))} partitions, "
            f"{s.get('inconsistency_count', 0)} cross-device inconsistencies"
        )
        for name, info in list(partitions.items())[:5]:
            summary.append(f"  pkey {name}: {info.get('name', '')} ({info.get('member_count', 0)} members, {info.get('type', '')})")

    # 7. Multicast
    mc = _load_json_safe('ib_multicast.json')
    if mc:
        s = mc.get('summary', {})
        summary.append(f"MULTICAST: {s.get('group_count', 0)} IB MC groups")
        for g in (mc.get('groups') or [])[:5]:
            summary.append(f"  mlid {g.get('mlid', '?')} pkey {g.get('pkey', '?')} members={g.get('members', '?')} {g.get('kind', '')}")

    # 8. QoS
    qos = _load_json_safe('ib_qos.json')
    if qos:
        s = qos.get('summary', {})
        summary.append(f"QOS: {s.get('profile_count', 0)} profiles, {s.get('inconsistency_count', 0)} inconsistencies")
        for prof in (qos.get('profiles') or [])[:3]:
            summary.append(f"  profile {prof.get('name', '?')} applied on {len(prof.get('applied_on', []))} devices")

    # 9. SHARP
    sh = _load_json_safe('ib_sharp_status.json')
    if sh and sh.get('enabled'):
        s = sh.get('summary', {})
        summary.append(
            f"SHARP: ENABLED, version {sh.get('version', '?')}, "
            f"{s.get('node_count', 0)} aggregation nodes, "
            f"{s.get('tree_count', len(sh.get('trees', [])))} trees"
        )
    elif sh is not None:
        summary.append("SHARP: not enabled on this fabric")

    # 10. Transceivers
    tr = _load_json_safe('transceiver_inventory.json')
    if tr:
        s = tr.get('summary', {})
        mixed = s.get('mixed_fw_models') or []
        summary.append(
            f"TRANSCEIVERS: {s.get('modules_count', s.get('total_modules', 0))} modules, "
            f"{s.get('unique_models', 0)} models, "
            f"mixed-FW: {', '.join(mixed) if mixed else 'none'}"
        )

    # 11. Logs
    logs = _load_json_safe('log_summary.json')
    if logs:
        summary.append(
            f"LOGS: {logs.get('critical', 0)} critical, {logs.get('error', 0)} errors, "
            f"{logs.get('warning', 0)} warnings, {logs.get('info', 0)} info"
        )
        for m in (logs.get('top_messages') or [])[:3]:
            summary.append(f"  {m.get('severity', '?').upper()} {m.get('device', '?')} x{m.get('count', '?')}: {m.get('sample', '')}")

    # 12. UFM (if reachable)
    try:
        ufm_url = os.environ.get('UFM_URL', '')
        if ufm_url:
            summary.append(f"UFM: integration configured at {ufm_url}")
    except Exception:
        pass

    return '\n'.join(summary), devices, device_health


def build_device_detail(hostname, devices, device_health):
    """Build IB-specific detail for one device: identity, GUID/LID,
    links to/from in topology, any link-error problem ports, P_Key membership."""
    detail = []
    ip = ''
    for dev_ip, dev_info in devices.items():
        if dev_info['hostname'] == hostname or dev_ip == hostname:
            ip = dev_ip
            hostname = dev_info['hostname']
            detail.append(f"DEVICE: {hostname} ({ip}) role={dev_info['role']}")
            break

    if not ip:
        return f"Device '{hostname}' not found in inventory."

    # assets.ini-driven identity
    health = device_health.get(hostname, {})
    if health:
        detail.append(
            f"  Model: {health.get('model', '?')}, FW: {health.get('release', '?')}, "
            f"Serial: {health.get('serial', '?')}, Status: {health.get('status', '?')}"
        )

    # Topology — GUID/LID + per-link neighbors
    topo = _load_json_safe('ib_topology.json')
    if topo:
        node = next((n for n in topo.get('nodes', []) if n.get('hostname') == hostname), None)
        if node:
            detail.append(f"  GUID: {node.get('guid', '?')}, LID: {node.get('lid', '?')}, type: {node.get('type', '?')}")
        links = topo.get('links', [])
        local_links = [l for l in links if l.get('src') == hostname or l.get('dst') == hostname]
        if local_links:
            detail.append(f"  IB LINKS ({len(local_links)}):")
            for l in local_links[:25]:
                if l.get('src') == hostname:
                    detail.append(f"    {l.get('src_port', '?')} -> {l.get('dst', '?')}:{l.get('dst_port', '?')} ({l.get('speed', '')})")
                else:
                    detail.append(f"    {l.get('dst_port', '?')} <- {l.get('src', '?')}:{l.get('src_port', '?')} ({l.get('speed', '')})")

    # Problem ports on this device
    le = _load_json_safe('ib_link_errors.json')
    if le:
        local_problems = [p for p in (le.get('problem_ports') or []) if p.get('device') == hostname]
        if local_problems:
            detail.append(f"  PROBLEM PORTS ON THIS DEVICE: {len(local_problems)}")
            for p in local_problems[:10]:
                detail.append(
                    f"    {p.get('severity', '?').upper()} {p.get('port', '?')} "
                    f"symbol_err={p.get('symbol_errors', 0)} link_down={p.get('link_downed', 0)} "
                    f"rcv_err={p.get('rcv_errors', 0)} -- {p.get('note', '')}"
                )

    # P_Key membership (which partitions this device belongs to)
    pk = _load_json_safe('ib_pkey.json')
    if pk:
        per_device = pk.get('per_device') or {}
        member_pkeys = per_device.get(hostname, [])
        if member_pkeys:
            detail.append(f"  P_KEY MEMBERSHIP: {', '.join(member_pkeys)}")

    return '\n'.join(detail) if detail else f"Device '{hostname}' found but no detailed data available."


def build_context_for_question(question, devices, device_health):
    """Build IB-specific extra context based on keywords in the question."""
    extra_context = []
    q_lower = question.lower()

    # Specific device mentions -> include full device detail
    for ip, dev in devices.items():
        if dev['hostname'].lower() in q_lower or ip in q_lower:
            extra_context.append(build_device_detail(dev['hostname'], devices, device_health))

    # Topology questions -> include the DOT graph
    if any(kw in q_lower for kw in ['topolog', 'connection', 'cable', 'wiring',
                                    'fat-tree', 'fat tree', 'fabric layout']):
        for base in (WEB_ROOT, LLDPQ_DIR):
            topo_dot = os.path.join(base, 'topology.dot')
            if os.path.exists(topo_dot):
                try:
                    with open(topo_dot) as f:
                        extra_context.append(f"TOPOLOGY (DOT):\n{f.read()[:3000]}")
                    break
                except Exception:
                    pass

    # SM / master / standby questions -> include full ib_sm_status.json
    if any(kw in q_lower for kw in ['sm ', 'subnet manager', 'master', 'standby',
                                    'opensm', 'sminfo']):
        sm = _load_json_safe('ib_sm_status.json')
        if sm:
            extra_context.append("FULL SM STATUS JSON:\n" + json.dumps(sm, indent=2)[:3000])

    # Link / flap / error questions -> include full ib_link_errors.json
    if any(kw in q_lower for kw in ['flap', 'down', 'link error', 'symbol error',
                                    'rcv error', 'critical port', 'warning port',
                                    'perfquery', 'iblinkinfo']):
        le = _load_json_safe('ib_link_errors.json')
        if le:
            extra_context.append("FULL LINK ERROR JSON:\n" + json.dumps(le, indent=2)[:3000])

    # P_Key questions
    if any(kw in q_lower for kw in ['pkey', 'p_key', 'p key', 'partition']):
        pk = _load_json_safe('ib_pkey.json')
        if pk:
            extra_context.append("FULL P_KEY JSON:\n" + json.dumps(pk, indent=2)[:3000])

    # Multicast questions
    if any(kw in q_lower for kw in ['multicast', 'mcast', 'mlid', 'ipoib', 'mgid',
                                    'nccl ring', 'mpi broadcast']):
        mc = _load_json_safe('ib_multicast.json')
        if mc:
            extra_context.append("FULL MULTICAST JSON:\n" + json.dumps(mc, indent=2)[:2500])

    # QoS / SL / VL
    if any(kw in q_lower for kw in ['qos', 'service level', 'sl ', 'vl ', 'sl-vl']):
        qos = _load_json_safe('ib_qos.json')
        if qos:
            extra_context.append("FULL QOS JSON:\n" + json.dumps(qos, indent=2)[:2500])

    # SHARP
    if any(kw in q_lower for kw in ['sharp', 'aggregation', 'reduction', 'nccl tree']):
        sh = _load_json_safe('ib_sharp_status.json')
        if sh:
            extra_context.append("FULL SHARP JSON:\n" + json.dumps(sh, indent=2)[:2500])

    # Transceiver / firmware / cable
    if any(kw in q_lower for kw in ['transceiver', 'optic', 'firmware', 'fw version',
                                    'mlxlink', 'cable', 'cmis', 'osfp']):
        tr = _load_json_safe('transceiver_inventory.json')
        if tr:
            # full inventory can be huge -- summary + first 30 modules
            summary = tr.get('summary', {})
            modules = tr.get('modules', [])[:30]
            extra_context.append(
                "TRANSCEIVER INVENTORY (summary + first 30 modules):\n"
                + json.dumps({'summary': summary, 'modules': modules}, indent=2)[:3500]
            )

    # UFM
    if 'ufm' in q_lower:
        url = os.environ.get('UFM_URL', '')
        extra_context.append(f"UFM CONFIG: URL={url or 'not set'}, "
                             f"TOKEN={'set' if os.environ.get('UFM_TOKEN') else 'unset'}, "
                             f"TLS_VERIFY={os.environ.get('UFM_VERIFY_TLS', 'false')}")

    return '\n\n'.join(extra_context)


def build_device_list(devices, device_health):
    """Token-economical device list for the LLM context: full detail for any
    device with a problem (unreachable, or has a problem port), one-line
    summary per role for the rest. Saves ~80% tokens on large fabrics."""

    # Pre-fetch IB link errors so we can tag affected devices
    le = _load_json_safe('ib_link_errors.json') or {}
    problem_ports = le.get('problem_ports') or []
    error_devices = {}  # hostname -> [severity, severity, ...]
    for p in problem_ports:
        error_devices.setdefault(p.get('device', ''), []).append(p.get('severity', '?'))

    problems = []
    healthy_by_role = {}

    for ip, dev in sorted(devices.items(), key=lambda x: x[1]['hostname']):
        h = device_health.get(dev['hostname'], {})
        status = h.get('status', 'unknown')
        role = dev['role']

        has_problem = False
        issue_tags = []

        if status not in ('ok', 'unknown'):
            has_problem = True
            issue_tags.append(f"STATUS:{status}")

        if dev['hostname'] in error_devices:
            sev_counts = {}
            for s in error_devices[dev['hostname']]:
                sev_counts[s] = sev_counts.get(s, 0) + 1
            sev_str = ', '.join(f"{c} {s}" for s, c in sev_counts.items())
            has_problem = True
            issue_tags.append(f"LINK_ERRORS:{sev_str}")

        if has_problem:
            tags = ' '.join(issue_tags)
            problems.append(
                f"  {dev['hostname']} ({ip}) role={role} "
                f"model={h.get('model', '?')} fw={h.get('release', '?')} {tags}"
            )
        else:
            healthy_by_role[role] = healthy_by_role.get(role, 0) + 1

    lines = []
    total = len(devices)
    healthy_total = total - len(problems)

    if problems:
        lines.append(f"PROBLEM DEVICES ({len(problems)}):")
        lines.extend(problems)

    healthy_summary = ', '.join(f"{count} {role}" for role, count in sorted(healthy_by_role.items(), key=lambda x: -x[1]))
    lines.append(f"\nHEALTHY: {healthy_total}/{total} devices ({healthy_summary})")
    lines.append("(Ask about any specific hostname for GUID/LID/links/problem-port detail.)")

    return '\n'.join(lines)


# ======================== SYSTEM PROMPTS ========================
# Two tiers: COMPACT for small/local models, FULL for cloud/large models

# Small models (ollama / tinyllama / llama3.2 / phi3, etc.) -- keep under ~600 tokens
SYSTEM_PROMPT_COMPACT = """You are LLDPq-IB AI, an NVIDIA InfiniBand fabric expert
embedded in a monitoring tool. You have access to LIVE data from a real IB fabric
(MLNX-OS switches + ConnectX HCAs). Treat the data below as ground truth.

RULES:
- ONLY use the data below. NEVER invent GUIDs, LIDs, hostnames, or counters.
- Reference actual hostnames, GUIDs, LIDs, and port names (IB1/N) from the data.
- Be concise. Use bullet points.
- Suggest MLNX-OS / ibutils diagnostics, never Cumulus/NVUE:
    show ib sm-info, show interfaces ib status, show interfaces ib link-diagnostics,
    show interfaces ib <port> transceiver diagnostics,
    ib sminfo, ib ibnetdiscover -p, ib iblinkinfo --line, ib perfquery -G <GUID>,
    ib ibqueryerrors --details, ib saquery -m, ib ibtracert -G <src> <dst>
- Severity:
    SM has NO Master                -> CRITICAL
    SM has multiple Masters / disagreement -> CRITICAL
    Link errors "critical" tier     -> CRITICAL
    Link errors "warning" tier      -> WARNING
    LinkDownedCounter increment > 0 -> WARNING (port flap suspect)
    Mixed transceiver firmware      -> WARNING
    All else                        -> INFO
- IB has no BGP, VLANs, or VRFs. Do NOT suggest those.

=== LIVE FABRIC DATA ===

{fabric_summary}

{device_list}

{extra_context}

=== END OF DATA ===

Answer the user's question using ONLY the data above."""

# Large models (Claude, GPT-4o, Gemini Pro, etc.) -- full reference + IB playbooks
SYSTEM_PROMPT_FULL = """You are LLDPq-IB AI, an NVIDIA InfiniBand fabric expert
embedded in a monitoring tool. You have access to LIVE data from a real IB fabric
(MLNX-OS switches + ConnectX HCAs). Treat ALL data below as ground truth.

# RESPONSE RULES
- ONLY use the data below. NEVER invent GUIDs, LIDs, hostnames, or counters.
- Always reference ACTUAL hostnames, GUIDs (0x... 16-hex), LIDs (decimal), and
  port names (IB1/N) from the data.
- Be concise. Use bullet points and headers.
- Rate issues: CRITICAL / WARNING / INFO. Priority order (high -> low):
    SM lost / multi-Master -> CRITICAL port errors -> port flap ->
    mixed transceiver firmware -> warnings -> cosmetic.
- Suggest MLNX-OS native CLI and ibutils. NEVER suggest Cumulus / NVUE / FRR.
- IB has no BGP, VLANs, VRFs, MAC tables. Do NOT suggest those.
- If data is insufficient, say EXACTLY what additional data you need.

# DATA SCHEMA REFERENCE

## ib_topology.json
Nodes have {{hostname, type ("switch"/"hca"/"router"), role, guid, lid, model}}.
Links have {{src, src_port, dst, dst_port, speed (e.g. "4xNDR")}}.
Summary has total_nodes, total_links, switches, hcas, speed_distribution.

## ib_sm_status.json
Master + standby Subnet Manager records. Master state="Master", standby="Standby".
- 0 Masters = CRITICAL (no fabric authority)
- >1 Master = CRITICAL (split-brain)
- disagreements[]: nodes that briefly thought they were Master

## ib_link_errors.json
Per-port counter-delta analysis. problem_ports[] lists each port with severity
("critical"/"warning") and the counters that crossed thresholds.
- symbol_errors > 10000 in 1h -> critical (cable / optic suspect)
- link_downed in last hour    -> warning (flap suspect)
- rcv_errors  growing         -> warning (signal integrity)

## ib_pkey.json
IB partitions (= "VLANs" equivalent). Each pkey has {{name, members[], type:
"full"|"limited"}}. Default partition is 0x7fff (full membership for all).
- inconsistencies > 0 = cross-device pkey mismatch (rare, usually misconfiguration).

## ib_multicast.json
groups[]: {{mgid, mlid, pkey, members, kind}}. Typical: IPoIB default,
NCCL ring, MPI broadcast.

## ib_qos.json
profiles[]: each profile has sl_to_vl (8 SLs typical). applied_on lists the
switches using the profile.

## ib_sharp_status.json (conditional)
SHARP = NVIDIA's in-network reduction tree. enabled=true means SHARP aggregation
is active on this fabric (NCCL accelerated). nodes[] = aggregators, trees[] =
active aggregation trees.

## transceiver_inventory.json
modules[]: per port {{device, port, vendor, vendor_pn, vendor_sn, fw_version,
cable_length, speed}}. Summary.mixed_fw_models lists models that have more than
one firmware version present (potential firmware-skew problem).

## log_summary.json
critical / error / warning / info counts plus top_messages[] examples.

# MLNX-OS NATIVE CLI (admin user, no sudo)
Diagnostic:
- show version, show inventory, show hostname
- show interfaces ib status                  -- per-port up/down + speed
- show interfaces ib link-diagnostics        -- physical layer codes per port
- show interfaces ib <port>                  -- detail for one port
- show interfaces ib <port> transceiver       -- vendor/PN/SN/FW
- show interfaces ib <port> transceiver diagnostics -- RX/TX power, temp
- show interfaces ib <port> counters          -- LinkDowned, Symbol, PortRcvErrors
- show ib sm-info, show ib smnodes
- show ib partition, show ib qos-profile
- show log [matching ERR|WARN|INFO]           -- IB switch syslog

# IBUTILS (CLI 'ib' prefix; MLNX-OS routes to shell)
- ib sminfo                                   -- SM master / state / sweep
- ib ibnetdiscover -p                         -- raw fabric topology
- ib iblinkinfo --line                        -- per-link counter snapshot
- ib perfquery -G <GUID>                      -- counters by GUID
- ib ibqueryerrors --details                  -- error-only summary
- ib saquery -m                               -- multicast group view
- ib ibtracert -G <src_guid> <dst_guid>       -- IB-layer path trace

# TROUBLESHOOTING PLAYBOOKS

## SM lost / disagreement
1. `show ib sm-info` on every switch -- confirm Master count
2. If 0 Masters -> raise priority of best candidate, restart SM
3. If >1 Master -> check sm_priority + sm_sl on all SMs
4. `ib sminfo` from a host to cross-verify

## Critical link errors on one port
1. `show interfaces ib <port> counters` -- which counter is non-zero?
2. `show interfaces ib <port> transceiver diagnostics` -- RX power below -8 dBm?
3. Swap cable. If error persists -> swap transceiver. Then ASIC port.
4. `ib perfquery -R -G <guid>` clears counters after fix.

## Port flap (LinkDownedCounter rising)
1. Both ends: `show interfaces ib <port> counters | grep -i down`
2. If only one end shows downs -> cable; if both -> ASIC / FW
3. Replace cable, re-check after 30 min.

## Mixed transceiver firmware
1. Group modules by vendor_pn from transceiver_inventory.json
2. For each PN with > 1 fw_version, schedule mlxlink FW push
3. The Transceiver page in this UI surfaces mixed-FW models in yellow.

## Topology validation
1. Local ib_topology.json vs ib ibnetdiscover output should match
2. If UFM configured -> use UFM page "Validate Topology" -- shows
   "only_in_local" and "only_in_ufm" GUID lists.

=== LIVE FABRIC DATA ===

{fabric_summary}

{device_list}

{extra_context}

=== END OF DATA ===

Answer the user's question using ONLY the data above."""

# Auto-select prompt based on provider
SMALL_MODEL_PROVIDERS = ('ollama',)

def get_system_prompt():
    if AI_PROVIDER in SMALL_MODEL_PROVIDERS:
        return SYSTEM_PROMPT_COMPACT
    return SYSTEM_PROMPT_FULL


# ======================== LLM PROXY ========================

def call_ollama_stream(messages):
    """Call Ollama API with streaming."""
    import urllib.request
    url = f"{OLLAMA_URL}/api/chat"
    payload = json.dumps({
        "model": AI_MODEL,
        "messages": messages,
        "stream": True
    }).encode()
    
    req = urllib.request.Request(url, data=payload, headers={'Content-Type': 'application/json'})
    try:
        resp = urllib.request.urlopen(req, timeout=120)
        for line in resp:
            try:
                chunk = json.loads(line.decode())
                content = chunk.get('message', {}).get('content', '')
                if content:
                    sse_event({"content": content})
                if chunk.get('done'):
                    break
            except json.JSONDecodeError:
                continue
    except Exception as e:
        sse_event({"error": str(e)}, event="error")


def call_openai_stream(messages):
    """Call OpenAI-compatible API with streaming (works for OpenAI, Claude via proxy, etc.)."""
    import urllib.request
    url = f"{AI_API_URL}/chat/completions"
    payload = json.dumps({
        "model": AI_MODEL,
        "messages": messages,
        "stream": True
    }).encode()
    
    headers = {
        'Content-Type': 'application/json',
        'Authorization': f'Bearer {AI_API_KEY}'
    }
    
    req = urllib.request.Request(url, data=payload, headers=headers)
    try:
        resp = urllib.request.urlopen(req, timeout=120)
        for line in resp:
            line = line.decode().strip()
            if line.startswith('data: '):
                data_str = line[6:]
                if data_str == '[DONE]':
                    break
                try:
                    chunk = json.loads(data_str)
                    delta = chunk.get('choices', [{}])[0].get('delta', {})
                    content = delta.get('content', '')
                    if content:
                        sse_event({"content": content})
                except json.JSONDecodeError:
                    continue
    except Exception as e:
        sse_event({"error": str(e)}, event="error")


def call_claude_stream(messages):
    """Call Anthropic Claude API with streaming."""
    import urllib.request
    url = f"{AI_API_URL}/messages" if '/messages' not in AI_API_URL else AI_API_URL
    
    # Convert from OpenAI message format to Claude format
    system_msg = ''
    claude_messages = []
    for m in messages:
        if m['role'] == 'system':
            system_msg = m['content']
        else:
            claude_messages.append({"role": m['role'], "content": m['content']})
    
    payload = json.dumps({
        "model": AI_MODEL,
        "max_tokens": 4096,
        "system": system_msg,
        "messages": claude_messages,
        "stream": True
    }).encode()
    
    headers = {
        'Content-Type': 'application/json',
        'x-api-key': AI_API_KEY,
        'anthropic-version': '2023-06-01'
    }
    
    req = urllib.request.Request(url, data=payload, headers=headers)
    try:
        resp = urllib.request.urlopen(req, timeout=120)
        for line in resp:
            line = line.decode().strip()
            if line.startswith('data: '):
                try:
                    chunk = json.loads(line[6:])
                    if chunk.get('type') == 'content_block_delta':
                        content = chunk.get('delta', {}).get('text', '')
                        if content:
                            sse_event({"content": content})
                except json.JSONDecodeError:
                    continue
    except Exception as e:
        sse_event({"error": str(e)}, event="error")


def call_llm_stream(messages):
    """Route to the appropriate LLM provider."""
    if AI_PROVIDER == 'ollama':
        call_ollama_stream(messages)
    elif AI_PROVIDER == 'claude':
        call_claude_stream(messages)
    else:  # openai or custom
        call_openai_stream(messages)


def call_llm_sync(messages):
    """Synchronous LLM call (for analysis). Returns full response text."""
    import urllib.request
    
    if AI_PROVIDER == 'ollama':
        url = f"{OLLAMA_URL}/api/chat"
        payload = json.dumps({"model": AI_MODEL, "messages": messages, "stream": False}).encode()
        headers = {'Content-Type': 'application/json'}
    elif AI_PROVIDER == 'claude':
        url = f"{AI_API_URL}/messages" if '/messages' not in AI_API_URL else AI_API_URL
        system_msg = ''
        claude_msgs = []
        for m in messages:
            if m['role'] == 'system':
                system_msg = m['content']
            else:
                claude_msgs.append({"role": m['role'], "content": m['content']})
        payload = json.dumps({"model": AI_MODEL, "max_tokens": 4096, "system": system_msg, "messages": claude_msgs}).encode()
        headers = {'Content-Type': 'application/json', 'x-api-key': AI_API_KEY, 'anthropic-version': '2023-06-01'}
    elif AI_PROVIDER == 'gemini':
        # Google Gemini API
        model = AI_MODEL or 'gemini-2.0-flash'
        url = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent?key={AI_API_KEY}"
        # Convert messages to Gemini format
        gemini_contents = []
        system_text = ''
        for m in messages:
            if m['role'] == 'system':
                system_text = m['content']
            elif m['role'] == 'user':
                gemini_contents.append({"role": "user", "parts": [{"text": m['content']}]})
            elif m['role'] == 'assistant':
                gemini_contents.append({"role": "model", "parts": [{"text": m['content']}]})
        # Prepend system text to first user message
        if system_text and gemini_contents:
            first_text = gemini_contents[0]['parts'][0]['text']
            gemini_contents[0]['parts'][0]['text'] = f"[System instruction: {system_text}]\n\n{first_text}"
        payload = json.dumps({"contents": gemini_contents}).encode()
        headers = {'Content-Type': 'application/json'}
    else:
        url = f"{AI_API_URL}/chat/completions"
        payload = json.dumps({"model": AI_MODEL, "messages": messages}).encode()
        headers = {'Content-Type': 'application/json', 'Authorization': f'Bearer {AI_API_KEY}'}
    
    req = urllib.request.Request(url, data=payload, headers=headers)
    try:
        resp = urllib.request.urlopen(req, timeout=500)
        result = json.loads(resp.read().decode())
        if AI_PROVIDER == 'ollama':
            return result.get('message', {}).get('content', '')
        elif AI_PROVIDER == 'claude':
            return result.get('content', [{}])[0].get('text', '')
        elif AI_PROVIDER == 'gemini':
            candidates = result.get('candidates', [])
            if candidates:
                parts = candidates[0].get('content', {}).get('parts', [])
                return parts[0].get('text', '') if parts else ''
            return result.get('error', {}).get('message', 'No response from Gemini')
        else:
            return result.get('choices', [{}])[0].get('message', {}).get('content', '')
    except Exception as e:
        return f"Error: {e}"


# ======================== ACTIONS ========================

def action_chat():
    """Handle chat message — synchronous response (fcgiwrap doesn't support SSE streaming)."""
    try:
        data = json.loads(POST_DATA)
    except Exception:
        error_json("Invalid JSON")

    question = data.get('message', '').strip()
    history = data.get('history', [])  # previous messages for context

    if not question:
        error_json("Empty message")

    # Bail out cleanly if the operator has not yet configured a provider.
    if not AI_PROVIDER or not AI_MODEL:
        error_json(
            "AI provider not configured. Click the Settings button in the "
            "top-right of the Ask AI page and choose a provider "
            "(ollama / openai / claude / gemini) and a model. The chat is "
            "disabled until a provider is set."
        )

    # Build context
    fabric_summary, devices, device_health = build_fabric_summary()
    extra_context = build_context_for_question(question, devices, device_health)
    device_list = build_device_list(devices, device_health)
    
    system_prompt = get_system_prompt().format(
        fabric_summary=fabric_summary,
        device_list=device_list,
        extra_context=extra_context
    )
    
    # Build messages array
    messages = [{"role": "system", "content": system_prompt}]
    
    # Add conversation history (last 10 messages for context window)
    for msg in history[-10:]:
        messages.append({"role": msg.get('role', 'user'), "content": msg.get('content', '')})
    
    messages.append({"role": "user", "content": question})
    
    # Synchronous LLM call
    response = call_llm_sync(messages)
    
    result_json({"success": True, "response": response})


def action_get_context():
    """Return the current fabric summary (for UI context indicator)."""
    fabric_summary, devices, device_health = build_fabric_summary()
    device_names = sorted(set(d['hostname'] for d in devices.values() if d['hostname']))
    result_json({
        "success": True,
        "summary": fabric_summary,
        "device_count": len(devices),
        "roles": {role: sum(1 for d in devices.values() if d['role'] == role) for role in set(d['role'] for d in devices.values())},
        "device_names": device_names,
    })


def action_get_config():
    """Return current AI configuration."""
    # Mask API key
    masked_key = ''
    if AI_API_KEY:
        masked_key = AI_API_KEY[:8] + '...' + AI_API_KEY[-4:] if len(AI_API_KEY) > 12 else '***'
    
    result_json({
        "success": True,
        "provider": AI_PROVIDER,
        "model": AI_MODEL,
        "api_url": AI_API_URL,
        "api_key_masked": masked_key,
        "ollama_url": OLLAMA_URL,
        "has_key": bool(AI_API_KEY),
        "proxy_url": AI_PROXY_URL,
    })


def action_save_config():
    """Save AI configuration to lldpq.conf."""
    try:
        data = json.loads(POST_DATA)
    except Exception:
        error_json("Invalid JSON")
    
    import shlex
    import subprocess, fcntl
    conf = '/etc/lldpq.conf'
    
    updates = {}
    if 'provider' in data:
        updates['AI_PROVIDER'] = data['provider']
    if 'model' in data:
        updates['AI_MODEL'] = data['model']
    if 'api_key' in data and data['api_key']:
        updates['AI_API_KEY'] = data['api_key']
    if 'api_url' in data:
        updates['AI_API_URL'] = data['api_url']
    if 'ollama_url' in data:
        updates['OLLAMA_URL'] = data['ollama_url']
    if 'proxy_url' in data:
        updates['AI_PROXY_URL'] = data['proxy_url']
    
    try:
        lock_fd = open(conf + '.lock', 'w')
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        try:
            with open(conf, 'r') as f:
                lines = f.readlines()
            for key, value in updates.items():
                rendered = shlex.quote(str(value))
                found = False
                for i, line in enumerate(lines):
                    if line.startswith(f'{key}='):
                        lines[i] = f'{key}={rendered}\n'
                        found = True
                        break
                if not found:
                    lines.append(f'{key}={rendered}\n')
            content = ''.join(lines)
            try:
                with open(conf, 'w') as f:
                    f.write(content)
            except PermissionError:
                subprocess.run(['sudo', '-n', 'tee', conf], input=content, capture_output=True, text=True, timeout=5)
        finally:
            fcntl.flock(lock_fd, fcntl.LOCK_UN)
            lock_fd.close()
    except Exception as e:
        error_json(f"Failed to save config: {e}")
    
    result_json({"success": True, "message": "AI configuration saved"})


def action_test_connection():
    """Test LLM connection."""
    try:
        data = json.loads(POST_DATA) if POST_DATA else {}
    except Exception:
        data = {}
    
    provider = data.get('provider', AI_PROVIDER)
    model = data.get('model', AI_MODEL)
    
    # Set proxy for test if provided
    proxy_url = data.get('proxy_url', '')
    if proxy_url:
        os.environ['http_proxy'] = proxy_url
        os.environ['https_proxy'] = proxy_url
    elif AI_PROXY_URL:
        os.environ['http_proxy'] = AI_PROXY_URL
        os.environ['https_proxy'] = AI_PROXY_URL
    
    messages = [
        {"role": "system", "content": "You are a helpful assistant. Reply with exactly: OK"},
        {"role": "user", "content": "Test connection. Reply with: OK"}
    ]
    
    start = time.time()
    try:
        if provider == 'ollama':
            import urllib.request
            url = data.get('ollama_url', OLLAMA_URL) + '/api/chat'
            payload = json.dumps({"model": model, "messages": messages, "stream": False}).encode()
            req = urllib.request.Request(url, data=payload, headers={'Content-Type': 'application/json'})
            resp = urllib.request.urlopen(req, timeout=30)
            result = json.loads(resp.read().decode())
            reply = result.get('message', {}).get('content', '')
            elapsed = round(time.time() - start, 1)
            result_json({"success": True, "reply": reply.strip(), "elapsed": elapsed, "model": model})
        elif provider == 'gemini':
            import urllib.request
            api_key = data.get('api_key', AI_API_KEY)
            # Set proxy if provided in test payload
            proxy_url = data.get('proxy_url', '')
            if proxy_url:
                os.environ['http_proxy'] = proxy_url
                os.environ['https_proxy'] = proxy_url
            url = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent?key={api_key}"
            payload = json.dumps({"contents": [{"role": "user", "parts": [{"text": "Test connection. Reply with exactly: OK"}]}]}).encode()
            headers = {'Content-Type': 'application/json'}
            req = urllib.request.Request(url, data=payload, headers=headers)
            resp = urllib.request.urlopen(req, timeout=30)
            result = json.loads(resp.read().decode())
            candidates = result.get('candidates', [])
            reply = candidates[0]['content']['parts'][0]['text'] if candidates else 'No response'
        else:
            # OpenAI-compatible
            import urllib.request
            api_url = data.get('api_url', AI_API_URL)
            api_key = data.get('api_key', AI_API_KEY)
            if provider == 'claude':
                url = f"{api_url}/messages" if '/messages' not in api_url else api_url
                payload = json.dumps({"model": model, "max_tokens": 100, "messages": [{"role": "user", "content": "Test. Reply: OK"}]}).encode()
                headers = {'Content-Type': 'application/json', 'x-api-key': api_key, 'anthropic-version': '2023-06-01'}
            else:
                url = f"{api_url}/chat/completions"
                payload = json.dumps({"model": model, "messages": messages}).encode()
                headers = {'Content-Type': 'application/json', 'Authorization': f'Bearer {api_key}'}
            req = urllib.request.Request(url, data=payload, headers=headers)
            resp = urllib.request.urlopen(req, timeout=30)
            result = json.loads(resp.read().decode())
            if provider == 'claude':
                reply = result.get('content', [{}])[0].get('text', '')
            else:
                reply = result.get('choices', [{}])[0].get('message', {}).get('content', '')
            elapsed = round(time.time() - start, 1)
            result_json({"success": True, "reply": reply.strip(), "elapsed": elapsed, "model": model})
    except Exception as e:
        elapsed = round(time.time() - start, 1)
        error_msg = str(e)
        if 'urlopen error' in error_msg:
            error_msg = f"Connection failed: {error_msg}. Is the service running?"
        result_json({"success": False, "error": error_msg, "elapsed": elapsed})


def action_list_models():
    """List available models from Ollama."""
    import urllib.request
    try:
        url = f"{OLLAMA_URL}/api/tags"
        req = urllib.request.Request(url)
        resp = urllib.request.urlopen(req, timeout=10)
        data = json.loads(resp.read().decode())
        models = [m.get('name', '') for m in data.get('models', [])]
        result_json({"success": True, "models": models})
    except Exception as e:
        result_json({"success": True, "models": [], "error": str(e)})


def action_analyze():
    """Run autonomous fabric health analysis."""
    fabric_summary, devices, device_health = build_fabric_summary()
    device_list = build_device_list(devices, device_health)
    
    prompt = f"""Analyze this network fabric health data and report any issues, anomalies, or concerns.
Be specific: mention device names, IPs, and exact metrics.
Categorize findings as: CRITICAL, WARNING, or INFO.
If everything looks healthy, say so briefly.

{fabric_summary}

DEVICE LIST:
{device_list}"""
    
    messages = [
        {"role": "system", "content": "You are a network health analyzer. Analyze the data and report findings categorized by severity. Be concise and specific."},
        {"role": "user", "content": prompt}
    ]
    
    response = call_llm_sync(messages)
    
    analysis = {
        "timestamp": time.time(),
        "analysis": response,
        "device_count": len(devices),
        "provider": AI_PROVIDER,
        "model": AI_MODEL,
    }
    
    # Save analysis
    try:
        with open(ANALYSIS_FILE, 'w') as f:
            json.dump(analysis, f, indent=2)
    except PermissionError:
        import subprocess
        subprocess.run(['sudo', '-n', 'tee', ANALYSIS_FILE],
                      input=json.dumps(analysis, indent=2), capture_output=True, text=True, timeout=10)
        subprocess.run(['sudo', '-n', 'chown', f'{LLDPQ_USER}:www-data', ANALYSIS_FILE], capture_output=True, timeout=5)
        subprocess.run(['sudo', '-n', 'chmod', '664', ANALYSIS_FILE], capture_output=True, timeout=5)
    
    result_json({"success": True, "analysis": response, "timestamp": analysis['timestamp']})


def action_get_analysis():
    """Get the latest autonomous analysis."""
    if not os.path.exists(ANALYSIS_FILE):
        result_json({"success": True, "analysis": "", "timestamp": 0, "stale": True})
    try:
        with open(ANALYSIS_FILE, 'r') as f:
            data = json.load(f)
        age = time.time() - data.get('timestamp', 0)
        data['success'] = True
        data['stale'] = age > 3600
        data['age_seconds'] = int(age)
        result_json(data)
    except Exception:
        result_json({"success": True, "analysis": "", "timestamp": 0, "stale": True})


# ======================== ROUTER ========================

if ACTION == 'chat':
    action_chat()
elif ACTION == 'get-context':
    action_get_context()
elif ACTION == 'get-config':
    action_get_config()
elif ACTION == 'save-config':
    action_save_config()
elif ACTION == 'test-connection':
    action_test_connection()
elif ACTION == 'list-models':
    action_list_models()
elif ACTION == 'analyze':
    action_analyze()
elif ACTION == 'get-analysis':
    action_get_analysis()
elif ACTION == 'get-log-messages':
    try:
        log_file = os.path.join(LLDPQ_DIR, 'monitor-results', 'log_summary.json')
        if os.path.exists(log_file):
            with open(log_file, 'r') as f:
                data = json.load(f)
            result_json({"success": True, "messages": data.get('recent_messages', {}), "totals": data.get('totals', {})})
        else:
            result_json({"success": True, "messages": {}, "totals": {}})
    except Exception as e:
        error_json(str(e))
else:
    error_json(f"Unknown action: {ACTION}")

PYTHON_SCRIPT
