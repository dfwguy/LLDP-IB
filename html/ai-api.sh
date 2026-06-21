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
    get-config|save-config|test-connection|list-models|get-audit)
        require_admin ;;
    analyze)
        # The hourly cron (lldpq-ai-analyze) calls this from loopback with no session.
        # Trust loopback only; any external caller still needs a valid session. nginx
        # sets REMOTE_ADDR to the real peer, so this cannot be spoofed from outside.
        case "${REMOTE_ADDR:-}" in
            127.0.0.1|::1) : ;;
            *) require_auth ;;
        esac ;;
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


def _load_ib_logs():
    """Return (totals, messages) for AI log context.

    IB hybrid mode writes ib_logs_summary.json (per-switch severity counts) plus
    raw per-switch lines in monitor-results/logs/<host>.log. Falls back to the
    legacy log_summary.json schema (top_messages/recent_messages) on non-MLNX-OS.
    """
    summ = _load_json_safe('ib_logs_summary.json')
    if summ:
        s = summ.get('summary', {})
        totals = {
            'critical': s.get('critical', 0),
            'error':    s.get('error', 0),
            'warning':  s.get('warning', 0),
            'info':     s.get('info', 0),
        }
        messages = {}
        for base in (MONITOR_RESULTS_DIR, os.path.join(WEB_ROOT, 'monitor-results')):
            logs_dir = os.path.join(base, 'logs')
            if not os.path.isdir(logs_dir):
                continue
            for dev in summ.get('devices', []):
                host = dev.get('device')
                actionable = (dev.get('critical', 0) or 0) + (dev.get('error', 0) or 0) + (dev.get('warning', 0) or 0)
                if not host or actionable == 0:
                    continue
                p = os.path.join(logs_dir, host + '.log')
                if os.path.exists(p):
                    try:
                        with open(p, errors='replace') as f:
                            lines = [ln.strip() for ln in f if ln.strip()][:30]
                        if lines:
                            messages[host] = lines
                    except Exception:
                        pass
            break
        return totals, messages

    # Legacy (Ethernet / ssh-mode) fallback
    legacy = _load_json_safe('log_summary.json')
    if legacy:
        totals = {
            'critical': legacy.get('critical', 0),
            'error':    legacy.get('error', 0),
            'warning':  legacy.get('warning', 0),
            'info':     legacy.get('info', 0),
        }
        msgs = legacy.get('recent_messages') or {}
        if not msgs:
            # synthesize from top_messages[] if present
            for m in (legacy.get('top_messages') or []):
                dev = m.get('device', '?')
                msgs.setdefault(dev, []).append(f"{m.get('severity', '?').upper()}: {m.get('sample', '')}")
        return totals, msgs

    return {}, {}


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

    # 2. Inventory + reachability from assets.ini.
    # IB schema (ib-assets.sh / ufm-adapter.py): tab-separated
    #   hostname  IP  MODEL  SERIAL  RELEASE  OS  UPTIME
    # There is NO trailing 1/0 status column (that was the Ethernet schema). A
    # switch only appears here if it was successfully collected -> presence = ok.
    device_health = {}
    reachable = 0
    for base in (LLDPQ_DIR, WEB_ROOT):
        ai_path = os.path.join(base, 'assets.ini')
        if not os.path.exists(ai_path):
            continue
        try:
            with open(ai_path) as f:
                for line in f:
                    line = line.rstrip('\n')
                    if not line.strip() or line.startswith('#'):
                        continue
                    parts = line.split('\t')
                    if len(parts) >= 2:
                        host = parts[0].strip()
                        device_health[host] = {
                            'ip':       parts[1].strip() if len(parts) > 1 else '',
                            'model':    parts[2].strip() if len(parts) > 2 else '',
                            'serial':   parts[3].strip() if len(parts) > 3 else '',
                            'release':  parts[4].strip() if len(parts) > 4 else '',
                            'uptime':   parts[6].strip() if len(parts) > 6 else '',
                            'status':   'ok',
                        }
                        reachable += 1
            break
        except Exception:
            pass
    # Devices in inventory but absent from assets.ini were not collected (treat as unreachable).
    for dev in devices.values():
        device_health.setdefault(dev['hostname'], {'status': 'unreachable'})
    summary.append(f"REACHABILITY: {reachable}/{len(devices)} switches collected (assets.ini); HCAs are not SSH-probed")

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

    # 6. P_Keys (IB partitions). ufm-adapter writes pkeys as a LIST of dicts.
    pk = _load_json_safe('ib_pkey.json')
    if pk:
        s = pk.get('summary', {})
        partitions = pk.get('pkeys') or []
        if isinstance(partitions, dict):  # tolerate legacy dict form
            partitions = [dict(v, pkey=k) for k, v in partitions.items()]
        summary.append(
            f"P_KEYS: {s.get('partition_count', s.get('total_pkeys', len(partitions)))} partitions, "
            f"{s.get('inconsistency_count', s.get('inconsistencies', 0))} cross-device inconsistencies, "
            f"{s.get('policy_violations', 0)} policy violations"
        )
        for p in partitions[:5]:
            names = ', '.join(p.get('names') or []) or '(unnamed)'
            summary.append(
                f"  pkey {p.get('pkey', '?')}: {names} "
                f"({p.get('device_count', len(p.get('devices', [])))} devices, policy={p.get('policy_status', '?')})"
            )

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

    # 11. Logs (IB hybrid: ib_logs_summary.json + logs/<host>.log; legacy fallback)
    log_totals, log_messages = _load_ib_logs()
    if log_totals:
        summary.append(
            f"LOGS: {log_totals.get('critical', 0)} critical, {log_totals.get('error', 0)} errors, "
            f"{log_totals.get('warning', 0)} warnings, {log_totals.get('info', 0)} info"
        )
        for host, lines in list(log_messages.items())[:3]:
            if lines:
                summary.append(f"  {host}: {lines[0][:160]}")

    # 12. UFM (if reachable) + active UFM events/alarms (collected by ufm-adapter.py)
    try:
        ufm_url = os.environ.get('UFM_URL', '')
        if ufm_url:
            summary.append(f"UFM: integration configured at {ufm_url}")
    except Exception:
        pass
    ev = _load_json_safe('ib_ufm_events.json')
    if ev and ev.get('events'):
        s = ev.get('summary', {})
        summary.append(
            f"UFM EVENTS: {s.get('total', len(ev['events']))} active "
            f"({s.get('critical', 0)} critical, {s.get('warning', 0)} warning, {s.get('minor', 0)} minor)"
        )
        for e in ev['events'][:4]:
            summary.append(f"  UFM {str(e.get('severity', '?')).upper()}: "
                           f"{e.get('object', '')} {(e.get('description') or e.get('name') or '')[:110]}")

    # 13. ibdiagnet -- latest fabric diagnostic headline (if one has been run)
    fd = _load_json_safe('ib_fabric_diag.json')
    if fd and fd.get('parsed'):
        t = fd.get('totals') or {}
        summary.append(
            f"IBDIAGNET (last run {fd.get('finished_at') or fd.get('generated_at', '?')}): "
            f"{t.get('errors', '?')} errors, {t.get('warnings', '?')} warnings (target={fd.get('target', '?')})"
        )

    # 14. Short-term trend headline (movement in CRITICAL ports across recent snapshots)
    try:
        _snaps = _load_snapshots(12)
        if len(_snaps) >= 3:
            _seq = [_snap_le(s)[0] for s in _snaps]
            if _seq[-1] != _seq[0]:
                summary.append(
                    f"TREND: CRITICAL ports {_seq[0]}->{_seq[-1]} over last {len(_seq)} samples "
                    f"({'WORSENING' if _seq[-1] > _seq[0] else 'improving'}) -- ask 'trend' for detail"
                )
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
        # ib_topology.json links use source_desc/target_desc + source_port/target_port.
        links = topo.get('links', [])
        local_links = [l for l in links if l.get('source_desc') == hostname or l.get('target_desc') == hostname]
        if local_links:
            detail.append(f"  IB LINKS ({len(local_links)}):")
            for l in local_links[:25]:
                if l.get('source_desc') == hostname:
                    detail.append(f"    {l.get('source_port', '?')} -> {l.get('target_desc', '?')}:{l.get('target_port', '?')} ({l.get('speed', '')})")
                else:
                    detail.append(f"    {l.get('target_port', '?')} <- {l.get('source_desc', '?')}:{l.get('source_port', '?')} ({l.get('speed', '')})")

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

    # P_Key membership (which partitions this device belongs to).
    # per_device entries are dicts like {"pkey": "0x7fff"}; tolerate plain strings.
    pk = _load_json_safe('ib_pkey.json')
    if pk:
        per_device = pk.get('per_device') or {}
        member_pkeys = per_device.get(hostname, [])
        pkey_strs = [m.get('pkey', '') if isinstance(m, dict) else str(m) for m in member_pkeys]
        pkey_strs = [s for s in pkey_strs if s]
        if pkey_strs:
            detail.append(f"  P_KEY MEMBERSHIP: {', '.join(pkey_strs)}")

    return '\n'.join(detail) if detail else f"Device '{hostname}' found but no detailed data available."


def read_collected_config(hostname, max_chars=15000):
    """Full collected running config for one switch (show running-config),
    saved by get-configs.sh at WEB_ROOT/configs/<hostname>.txt."""
    try:
        path = os.path.join(WEB_ROOT, 'configs', f'{hostname}.txt')
        if not os.path.isfile(path):
            return ''
        with open(path, 'r') as f:
            cfg = f.read().strip()
        if not cfg:
            return ''
        if len(cfg) > max_chars:
            cfg = cfg[:max_chars] + f"\n... (truncated; {len(cfg)} chars total)"
        return f"FULL RUNNING CONFIG -- {hostname} (show running-config):\n{cfg}"
    except Exception:
        return ''


def build_all_collected_configs(devices=None, max_per_device=2500, max_total=120000):
    """Phase 1: every collected running config on disk (truncated per device) for
    fabric-wide config analysis / drift detection. Reads WEB_ROOT/configs/*.txt DIRECTLY
    so it works even when devices.yaml hostnames differ from the collected config
    filenames (written by get-configs.sh via `show running-config`)."""
    config_dir = os.path.join(WEB_ROOT, 'configs')
    if not os.path.isdir(config_dir):
        return ''
    out, total = [], 0
    for path in sorted(glob.glob(os.path.join(config_dir, '*.txt'))):
        hn = os.path.basename(path)[:-4]  # strip .txt
        try:
            with open(path, 'r') as f:
                cfg = f.read().strip()
        except Exception:
            continue
        if not cfg:
            continue
        block = cfg[:max_per_device]
        if len(cfg) > max_per_device:
            block += f"\n... (truncated; {len(cfg)} total)"
        entry = f"----- {hn} -----\n{block}"
        if total + len(entry) > max_total:
            out.append("... (remaining switch configs omitted for length)")
            break
        out.append(entry)
        total += len(entry)
    if not out:
        return ''
    return ("FULL COLLECTED RUNNING CONFIGS (all switches, show running-config; "
            "truncated per device):\n\n" + "\n\n".join(out))


def _mr_path(*parts):
    """Resolve a monitor-results file, preferring LLDPQ_DIR then the synced WEB_ROOT copy."""
    p1 = os.path.join(LLDPQ_DIR, 'monitor-results', *parts)
    if os.path.exists(p1):
        return p1
    return os.path.join(WEB_ROOT, 'monitor-results', *parts)


def _load_json_file(path):
    try:
        with open(path, 'r') as f:
            return json.load(f)
    except Exception:
        return None


def build_transceiver_context(hosts=None, max_chars=9000):
    """Transceiver/cable inventory per module: vendor/part/serial/FW + health/temp, plus
    summary. Reads transceiver_inventory.json (UFM cable_info via ufm-adapter.py)."""
    inv = _load_json_file(_mr_path('transceiver_inventory.json'))
    if not inv or not inv.get('modules'):
        return ''
    mods = [m for m in inv['modules'] if (not hosts or m.get('device') in hosts)]
    if not mods:
        return ''
    lines = ["TRANSCEIVER INVENTORY (device/port: vendor part sn fw health temp):"]
    for m in mods[:250]:
        lines.append(f"  {m.get('device','?')}/{m.get('port','?')}: {m.get('vendor','')} "
                     f"{m.get('part_number','')} sn={m.get('serial','') or m.get('serial_number','')} "
                     f"fw={m.get('fw_version','')} health={m.get('health','')} temp={m.get('temperature','')}")
    s = inv.get('summary') or {}
    if s:
        lines.append(f"  SUMMARY: {s.get('total_modules')} modules, {s.get('unique_models')} models, "
                     f"mixed-fw={s.get('mixed_fw_models')}")
    return '\n'.join(lines)[:max_chars]


def build_hardware_context(hosts=None, max_chars=9000):
    """Per-switch hardware: sensors/thermal/PSU/fan/memory (raw collected text written
    by ib-hw-collect.sh to monitor-results/hardware-data/<host>_hardware.txt)."""
    hw_dir = _mr_path('hardware-data')
    if not os.path.isdir(hw_dir):
        return ''
    out, total = ["HARDWARE (per-switch sensors/thermal/PSU/fan/memory):"], 0
    for f in sorted(glob.glob(os.path.join(hw_dir, '*_hardware.txt'))):
        host = os.path.basename(f).replace('_hardware.txt', '')
        if hosts and host not in hosts:
            continue
        try:
            with open(f, 'r') as fh:
                content = fh.read().strip()
        except Exception:
            continue
        if not content:
            continue
        block = f"--- {host} ---\n{content[:1400]}"
        if total + len(block) > max_chars:
            out.append("... (more switches omitted)")
            break
        out.append(block)
        total += len(block)
    return '\n\n'.join(out) if len(out) > 1 else ''


def build_ibdiag_context(max_chars=4500):
    """Latest ibdiagnet fabric diagnostic (run on the UFM appliance, parsed by
    process_ibdiagnet.py into ib_fabric_diag.json). The richest fabric-wide diagnostic:
    per-stage warning/error counts, BER / credit-loop / bad-GUID findings, fabric
    summary, cable count. Read-only; absent until a diagnostic has been run."""
    d = _load_json_safe('ib_fabric_diag.json')
    if not d or not d.get('parsed'):
        return ''
    t = d.get('totals') or {}
    lines = [
        "LATEST IBDIAGNET FABRIC DIAGNOSTIC (Diagnostics -> Fabric Diagnostic):",
        f"  run={d.get('finished_at') or d.get('generated_at', '?')} "
        f"target={d.get('target', '?')} version={d.get('version', '?')}",
        f"  TOTALS: {t.get('errors', '?')} errors, {t.get('warnings', '?')} warnings",
    ]
    stages = [s for s in (d.get('stages') or []) if (s.get('errors') or s.get('warnings'))]
    if stages:
        lines.append("  STAGES WITH FINDINGS:")
        for s in stages[:25]:
            c = f" -- {s.get('comment')}" if s.get('comment') else ""
            lines.append(f"    {s.get('name', '?')}: {s.get('errors', 0)} err, {s.get('warnings', 0)} warn{c}")
    elif d.get('stages'):
        lines.append("  STAGES: all checks passed (0 errors / 0 warnings)")
    for e in (d.get('top_errors') or [])[:8]:
        lines.append(f"  -E- {e}")
    for w in (d.get('top_warnings') or [])[:5]:
        lines.append(f"  -W- {w}")
    fs = [ln for ln in (d.get('fabric_summary') or []) if ln]
    if fs:
        lines.append("  FABRIC SUMMARY:")
        for ln in fs[:20]:
            lines.append(f"    {ln}")
    cab = d.get('cables') or {}
    if cab.get('entries'):
        lines.append(f"  CABLES: {cab.get('entries')} (source={cab.get('source')})")
    return '\n'.join(lines)[:max_chars]


def _load_snapshots(limit=12):
    """Up to <limit> most-recent fabric snapshots (oldest->newest) written by
    ufm-adapter.py to monitor-results/snapshots/. Used for short-term trend analysis."""
    snaps = []
    for base in (os.path.join(WEB_ROOT, 'monitor-results'), MONITOR_RESULTS_DIR):
        snap_dir = os.path.join(base, 'snapshots')
        if not os.path.isdir(snap_dir):
            continue
        files = sorted(glob.glob(os.path.join(snap_dir, 'lldpq-ib-*.json')))[-limit:]
        for p in files:
            try:
                with open(p) as f:
                    snaps.append(json.load(f))
            except Exception:
                pass
        if snaps:
            break
    return snaps


def _snap_le(s):
    m = ((s.get('ib_link_errors') or {}).get('summary') or {})
    return (int(m.get('critical', m.get('critical_count', 0)) or 0),
            int(m.get('warning', m.get('warning_count', 0)) or 0),
            int(m.get('flapping', m.get('flapping_1h', 0)) or 0))


def build_trend_context(limit=12, max_chars=2500):
    """Short-term trend across the last N snapshots (~N*10 min): link-error counts,
    SM master, topology size, and newly-appeared problem ports. Lets the model spot
    DEGRADATION over time ('rising 3 cycles') instead of a single snapshot."""
    snaps = _load_snapshots(limit)
    if len(snaps) < 2:
        return ''
    crit = [_snap_le(s)[0] for s in snaps]
    warn = [_snap_le(s)[1] for s in snaps]
    flap = [_snap_le(s)[2] for s in snaps]

    def arrow(seq):
        if len(seq) < 2 or seq[-1] == seq[0]:
            return 'flat'
        return 'RISING' if seq[-1] > seq[0] else 'falling'

    lines = [f"SHORT-TERM TREND (last {len(snaps)} samples, ~{len(snaps) * 10} min, oldest->newest):",
             f"  CRITICAL ports: {crit}  ({arrow(crit)})",
             f"  WARNING ports:  {warn}  ({arrow(warn)})",
             f"  flapping(1h):   {flap}  ({arrow(flap)})"]

    def topo_n(s):
        ts = ((s.get('ib_topology') or {}).get('summary') or {})
        return int(ts.get('total_links', 0) or 0), int(ts.get('total_nodes', 0) or 0)

    l0, n0 = topo_n(snaps[0])
    l1, n1 = topo_n(snaps[-1])
    if l0 != l1 or n0 != n1:
        note = 'links DROPPED -- possible cable pull/down' if l1 < l0 else 'links added'
        lines.append(f"  TOPOLOGY CHANGE: links {l0}->{l1}, nodes {n0}->{n1} ({note})")

    def master(s):
        sm = s.get('ib_sm_status') or {}
        ms = [x for x in (sm.get('sms') or []) if str(x.get('state', '')).lower() == 'master']
        return ms[0].get('guid') if ms else sm.get('master_guid')

    m0, m1 = master(snaps[0]), master(snaps[-1])
    if m0 and m1 and m0 != m1:
        lines.append(f"  SM MASTER CHANGED: {str(m0)[:18]}... -> {str(m1)[:18]}...")

    def ports(s):
        return {f"{p.get('device')}:{p.get('port')}"
                for p in ((s.get('ib_link_errors') or {}).get('problem_ports') or [])}

    new_ports = ports(snaps[-1]) - ports(snaps[0])
    if new_ports:
        lines.append(f"  NEW PROBLEM PORTS since oldest sample: {', '.join(sorted(new_ports)[:10])}")
    return '\n'.join(lines)[:max_chars]


def build_ufm_events_context(max_chars=3000):
    """Active UFM events/alarms collected by ufm-adapter.py into ib_ufm_events.json.
    Lets the model cross-reference its own findings against what UFM itself is flagging."""
    ev = _load_json_safe('ib_ufm_events.json')
    if not ev or not ev.get('events'):
        return ''
    s = ev.get('summary', {})
    lines = [f"UFM ACTIVE EVENTS/ALARMS ({s.get('total', len(ev['events']))} total: "
             f"{s.get('critical', 0)} critical, {s.get('warning', 0)} warning, {s.get('minor', 0)} minor):"]
    for e in ev['events'][:40]:
        lines.append(f"  {str(e.get('severity', '?')).upper()} [{e.get('type', '?')}] "
                     f"{e.get('object', '')} -- {(e.get('description') or e.get('name') or '')[:140]} "
                     f"({e.get('timestamp', '')})")
    return '\n'.join(lines)[:max_chars]


def _audit(kind, device, command, ok):
    """Append a one-line JSON record for every LIVE command the AI executes. The AI runs
    real (read-only) switch commands, so we keep an operator-reviewable trail
    (who/when/what/result). Best-effort; never raises."""
    try:
        rec = {
            'ts': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
            'user': os.environ.get('LLDPQ_AUTH_USER', '?'),
            'kind': kind, 'device': device, 'command': command, 'ok': bool(ok),
        }
        line = json.dumps(rec) + '\n'
        for path in (os.path.join(WEB_ROOT, 'monitor-results', 'ai-audit.log'),
                     '/tmp/lldpq-ai-audit.log'):
            try:
                with open(path, 'a') as f:
                    f.write(line)
                return
            except Exception:
                continue
    except Exception:
        pass


def build_context_for_question(question, devices, device_health):
    """Build IB-specific extra context based on keywords in the question."""
    extra_context = []
    q_lower = question.lower()
    mentioned_any = False
    mentioned_hosts = []

    # Specific device mentions -> include full device detail + its running config
    for ip, dev in devices.items():
        if dev['hostname'].lower() in q_lower or ip in q_lower:
            mentioned_any = True
            mentioned_hosts.append(dev['hostname'])
            extra_context.append(build_device_detail(dev['hostname'], devices, device_health))
            _cfg = read_collected_config(dev['hostname'])
            if _cfg:
                extra_context.append(_cfg)

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
                                    'perfquery', 'iblinkinfo', 'ber', 'fec', 'crc',
                                    'bit error']):
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

    # Transceiver / optical / firmware / cable -> host-filtered transceiver inventory.
    # (IB has no separate optical-DOM/BER pipeline; transceiver health/temp + the link
    # error JSON above cover the optical/BER questions.)
    _hf = mentioned_hosts or None
    if any(kw in q_lower for kw in ['transceiver', 'optic', 'optical', 'firmware', 'fw version',
                                    'mlxlink', 'cable', 'cmis', 'osfp', 'qsfp', 'sfp', 'dom', 'module']):
        _b = build_transceiver_context(_hf)
        if _b:
            extra_context.append(_b)

    # Hardware: sensors / thermal / PSU / fan / memory (ib-hw-collect.sh raw text)
    if any(kw in q_lower for kw in ['hardware', 'sensor', 'temperature', 'temp', 'psu',
                                    'power supply', 'fan', 'cpu', 'memory', 'thermal', 'health']):
        _b = build_hardware_context(_hf)
        if _b:
            extra_context.append(_b)

    # Config / consistency / audit questions -> feed actual running configs (Phase 1).
    if any(kw in q_lower for kw in ['config', 'consistency', 'audit', 'compare',
                                    'drift', 'running-config', 'running config',
                                    'mismatch', 'validate', 'baseline']):
        # Fabric-wide config question (no specific switch named) -> feed every switch's
        # actual running config so the model can do real drift/consistency analysis.
        if not mentioned_any:
            _allcfg = build_all_collected_configs(devices)
            if _allcfg:
                extra_context.append(_allcfg)

    # ibdiagnet / fabric diagnostic -> latest parsed ibdiagnet report
    if any(kw in q_lower for kw in ['ibdiagnet', 'fabric diagnostic', 'diagnostic report',
                                    'credit loop', 'credit-loop', 'deadlock', 'bad guid',
                                    'duplicate guid', 'fabric scan', 'routing']):
        _b = build_ibdiag_context()
        if _b:
            extra_context.append(_b)

    # Trend / degradation / over-time questions -> short-term snapshot trend
    if any(kw in q_lower for kw in ['trend', 'degrad', 'over time', 'history', 'historical',
                                    'rising', 'growing', 'worse', 'worsen', 'getting',
                                    'progress', 'since', 'last hour', 'last day', 'compare to',
                                    'compared to', 'change over']):
        _b = build_trend_context()
        if _b:
            extra_context.append(_b)

    # UFM events / alarms + config
    if any(kw in q_lower for kw in ['ufm', 'alarm', 'event']):
        _b = build_ufm_events_context()
        if _b:
            extra_context.append(_b)
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
- Suggest only verified MLNX-OS native CLI or LLDPq-IB diagnostic pages:
    show ib sm, show ib smnodes, show ib partition,
    show interfaces ib status, show interfaces ib link-diagnostics,
    show interfaces ib <port>, show interfaces ib <port> counters,
    show interfaces ib <port> transceiver diagnostics,
    Diagnostics -> Local Fabric Scan, Diagnostics -> Fabric Diagnostic (ibdiagnet on UFM)
- Severity:
    SM has NO Master                -> CRITICAL
    SM has multiple Masters / disagreement -> CRITICAL
    Link errors "critical" tier     -> CRITICAL
    Link errors "warning" tier      -> WARNING
    LinkDownedCounter increment > 0 -> WARNING (port flap suspect)
    Mixed transceiver firmware      -> WARNING
    All else                        -> INFO
- IB has no BGP, VLANs, or VRFs. Do NOT suggest those.

QUICK IB PLAYBOOKS (use when relevant):
- SM lost (0 Masters): raise sm_priority on best candidate + restart SM; cross-check
  with `show ib sm` / `show ib smnodes`; verify on the UFM appliance.
- Multiple Masters (split-brain): compare sm_priority + sm_sl across all SMs; only one
  should be highest priority.
- Critical link errors on a port: `show interfaces ib <port> counters` (which counter?),
  then `show interfaces ib <port> transceiver diagnostics` (RX power < -8 dBm?); clean,
  then swap cable, then transceiver, then ASIC port.
- Port flap (LinkDownedCounter rising): check both ends' counters; one end down => cable,
  both => ASIC/FW; replace cable, recheck after 30 min.
- Mixed transceiver firmware: group by part number; schedule FW alignment for any PN
  with >1 fw_version.
- P_Key inconsistency: a partition present on some switches but not others usually means
  a missed config push; re-apply the partition policy.

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
- Suggest verified MLNX-OS native CLI and LLDPq-IB diagnostics. NEVER suggest Cumulus / NVUE / FRR.
- Do NOT suggest running individual `ib <utility>` commands on MLNX-OS switches:
  on MLNX-OS 3.12 the `ib` keyword is an ibdiagnet wrapper, not standalone ibutils.
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
IB partitions (= "VLANs" equivalent). pkeys[] is a LIST; each entry has
{{pkey ("0x7fff"), names[], devices[], device_count, ipoib_states[], consistent,
policy_status}}. Default partition is 0x7fff. per_device{{host:[{{pkey}}...]}}.
summary has partition_count, inconsistency_count, policy_violations.
- inconsistency_count > 0 = cross-device pkey mismatch (rare, usually misconfiguration).

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
modules[]: per port {{device, port, vendor, part_number, serial, fw_version,
identifier, technology, length, temperature, health}}. Summary.mixed_fw_models lists
models that have more than one firmware version present (potential firmware-skew problem).
The chat is also fed a compact TRANSCEIVER INVENTORY block when the question is about
optics/firmware/cables (filtered to the named switch when one is mentioned).

## hardware-data/<host>_hardware.txt
Raw per-switch sensors/thermal/PSU/fan/memory text (from ib-hw-collect.sh). A HARDWARE
block is fed to the chat for temperature / PSU / fan / memory / health questions.

## ib_logs_summary.json
Per-switch actionable log severities. summary{{critical,error,warning,info,total}};
devices[]{{device,critical,error,warning,info,total}}. Raw lines per switch are in
monitor-results/logs/<host>.log.

## ib_fabric_diag.json (latest ibdiagnet run, conditional)
Parsed ibdiagnet output (the richest fabric-wide diagnostic, run on the UFM appliance).
totals{{errors,warnings}}; stages[]{{name,errors,warnings,comment}} (per-check: Bad
GUIDs/LIDs, Link Speed, Credit Loops, Routing, SHARP, ...); top_errors[]/top_warnings[]
(raw -E-/-W- lines); fabric_summary[] (node/switch/CA/link counts). A LATEST IBDIAGNET
block is fed when the question is about ibdiagnet / credit loops / bad GUIDs / routing.
This is authoritative for credit-loop, routing and BER-class issues -- prefer it.

## ib_ufm_events.json (conditional)
Active UFM events/alarms. summary{{total,critical,warning,minor,info}};
events[]{{severity,type,name,object,description,timestamp}}. Fed when the question is
about UFM / alarms / events. Cross-reference these against your own findings.

## short-term trend (snapshots/, conditional)
A SHORT-TERM TREND block (last ~12 snapshots, 10 min apart) is fed for trend / "over
time" / degradation questions: CRITICAL/WARNING/flapping port counts oldest->newest,
SM master changes, topology link/node changes, and newly-appeared problem ports. Use it
to distinguish a steady-state warning from an actively DEGRADING link.

# MLNX-OS NATIVE CLI (admin user, no sudo)
Diagnostic:
- show version, show inventory, show system type, show hosts
- show interfaces ib status                  -- per-port up/down + speed
- show interfaces ib link-diagnostics        -- physical layer codes per port
- show interfaces ib <port>                  -- detail for one port
- show interfaces ib <port> transceiver       -- vendor/PN/SN/FW
- show interfaces ib <port> transceiver diagnostics -- RX/TX power, temp
- show interfaces ib <port> counters          -- LinkDowned, Symbol, PortRcvErrors
- show ib sm, show ib smnodes
- show ib partition
- show log [matching ERR|WARN|INFO]           -- IB switch syslog

# FABRIC-WIDE DIAGNOSTICS
- Local Fabric Scan page                      -- ibutils from the LLDPq-IB container
- Fabric Diagnostic page                      -- ibdiagnet on the UFM appliance

# TROUBLESHOOTING PLAYBOOKS

## SM lost / disagreement
1. `show ib sm` / `show ib smnodes` on switches -- confirm local SM state
2. If 0 Masters -> raise priority of best candidate, restart SM
3. If >1 Master -> check sm_priority + sm_sl on all SMs
4. Run Diagnostics -> Local Fabric Scan or Fabric Diagnostic to cross-verify

## Critical link errors on one port
1. `show interfaces ib <port> counters` -- which counter is non-zero?
2. `show interfaces ib <port> transceiver diagnostics` -- RX power below -8 dBm?
3. Swap cable. If error persists -> swap transceiver. Then ASIC port.
4. After the fix, re-run Diagnostics -> Local Fabric Scan to confirm the counters stop growing.

## Port flap (LinkDownedCounter rising)
1. Both ends: `show interfaces ib <port> counters` -- check the LinkDowned counter.
2. If only one end shows downs -> cable; if both -> ASIC / FW
3. Replace cable, re-check after 30 min.

## Mixed transceiver firmware
1. Group modules by vendor_pn from transceiver_inventory.json
2. For each PN with > 1 fw_version, schedule mlxlink FW push
3. The Transceiver page in this UI surfaces mixed-FW models in yellow.

## Topology validation
1. Compare ib_topology.json against Diagnostics -> Local Fabric Scan output.
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


# ======================== LIVE SWITCH TOOL (read-only) ========================

TOOL_INSTRUCTIONS = """
=== LIVE SWITCH TOOL (read-only) ===
When the static fabric data above is not enough, you may pull LIVE read-only data
from a switch by writing a tool call on its own line, exactly:
[RUN: <device> <command>]
  - <device> = a switch hostname from the fabric (e.g. nvis-ib-comp-leaf-01).
  - <command> = a READ-ONLY MLNX-OS show/diagnostic command. Examples:
      show version  |  show inventory  |  show interfaces ib status  |
      show interfaces ib link-diagnostics  |  show interfaces ib <port> counters  |
      show ib sm  |  show ib smnodes  |  show ib partition  |  show running-config  |
      show temperature  |  show power  |  show log matching ERR
    Write/config commands (configure terminal, reboot, write memory, ib sm
    start/stop, mlxfwmanager, ...) are blocked by the backend and will be rejected.
    On MLNX-OS the `ib` keyword is the ibdiagnet wrapper, so prefer native `show`
    commands; for fabric-wide ibutils use the Diagnostics pages, not [RUN:].
  - Emit at most 3 tool calls per turn. After you receive "TOOL RESULTS", continue;
    request more only if truly needed.
  - When you have enough, give your FINAL answer with NO [RUN: ...] / [RUNALL: ...] lines.
  - Prefer the collected data above; use live tools only when current state is needed.

For a fabric-wide check, fan ONE command out to many switches IN PARALLEL:
[RUNALL: <target> <command>]
  - <target> = "all" (every switch) or a role/name substring (e.g. leaf, spine).
  - Same read-only command rules as [RUN:]. Use this instead of many [RUN:] lines when
    comparing the same thing across switches (e.g. show ib sm on all leaves).
  - At most one fan-out per turn; results return per switch.

To check how two endpoints connect through the fabric (graph-based, read-only):
[PATH: <source> <dest>]
  - <source>/<dest> = switch/HCA hostnames from the topology. Returns the hop-by-hop
    path over the discovered IB topology (or where it breaks). Use for "how does A
    reach B", partition, or missing-link questions. (IB has no live IP tracepath; this
    is the topology equivalent.)

=== REMEDIATION SUGGESTIONS ===
When you recommend a command the operator should RUN to investigate or fix something, put
it on its own line exactly as:
[FIX: <device-or-group> <command>]
  - This is a SUGGESTION rendered as a one-click button — you do NOT execute it. It opens
    the Command Runner prefilled; the operator reviews and runs it.
  - Use a real switch/role name and a concrete MLNX-OS command. Read-only show/diagnostic
    commands run directly; configuration changes are applied manually by the admin
    (LLDPq-IB is monitoring-only and the Command Runner only executes read-only commands).
  - Never suggest destructive commands.
"""


def run_device_tool(device, command, cookie):
    """Run ONE read-only switch command by invoking ib-api.sh's run-device-command
    as a subprocess. This reuses its exact read-only whitelist, admin auth (via the
    forwarded session cookie) and ssh exec — nothing is duplicated. Never raises."""
    import subprocess
    try:
        body = json.dumps({'device': device, 'command': command})
        env = dict(os.environ)
        env['REQUEST_METHOD'] = 'POST'
        env['QUERY_STRING'] = 'action=run-device-command'
        env['CONTENT_TYPE'] = 'application/json'
        env['CONTENT_LENGTH'] = str(len(body.encode('utf-8')))
        if cookie:
            env['HTTP_COOKIE'] = cookie
        proc = subprocess.run(
            ['bash', os.path.join(WEB_ROOT, 'ib-api.sh')],
            input=body, env=env, capture_output=True, text=True, timeout=60
        )
        raw = proc.stdout or ''
        for sep in ('\r\n\r\n', '\n\n'):
            if sep in raw:
                raw = raw.split(sep, 1)[1]
                break
        d = json.loads(raw.strip())
        if d.get('success'):
            ok, out = True, (d.get('output') or '(no output)')
        else:
            ok, out = False, (d.get('error') or 'command rejected')
    except subprocess.TimeoutExpired:
        ok, out = False, 'tool timed out'
    except Exception as e:
        ok, out = False, f'tool error: {e}'
    _audit('RUN', device, command, ok)
    return ok, out


def run_dispatch(target, command, devices, cookie, max_devices=60, pool=8, per_out=1200):
    """Phase 3: run ONE read-only command on many switches in PARALLEL (fan-out).
    target = 'all'/'*' or a role/hostname substring (e.g. 'leaf', 'spine').
    Returns (hostnames, {hostname: (ok, output)}). Reuses run_device_tool per device."""
    from concurrent.futures import ThreadPoolExecutor
    t = (target or '').strip().lstrip('@').lower()
    targets = []
    for ip, dev in devices.items():
        hn = dev.get('hostname', '')
        role = (dev.get('role', '') or '').lower()
        if not hn:
            continue
        if t in ('all', '*', '') or t in role or t in hn.lower():
            targets.append(hn)
    targets = sorted(set(targets))[:max_devices]
    results = {}
    if not targets:
        return targets, results

    def _one(h):
        ok, out = run_device_tool(h, command, cookie)
        return h, ok, (out or '')[:per_out]

    try:
        with ThreadPoolExecutor(max_workers=min(pool, len(targets))) as ex:
            for h, ok, out in ex.map(_one, targets):
                results[h] = (ok, out)
    except Exception as e:
        for h in targets:
            results.setdefault(h, (False, f'dispatch error: {e}'))
    return targets, results


def run_topology_path(src, dst):
    """IB-native read-only path discovery: shortest path between two endpoints over
    ib_topology.json (BFS), mirroring the Tracepath page's client-side logic. src/dst
    are hostnames (exact, else unique substring). No SSH; pure graph lookup. On
    MLNX-OS there is no live IP tracepath, so this topology path is the IB equivalent."""
    topo = _load_json_file(_mr_path('ib_topology.json'))
    if not topo or not topo.get('links'):
        return False, 'no topology data (ib_topology.json) available'
    nodes = {n.get('hostname') for n in topo.get('nodes', []) if n.get('hostname')}

    def resolve(x):
        x = (x or '').strip()
        if x in nodes:
            return x
        exact = [h for h in nodes if x.lower() == h.lower()]
        if exact:
            return exact[0]
        sub = [h for h in nodes if x.lower() in h.lower()]
        return sub[0] if len(sub) == 1 else None

    s, d = resolve(src), resolve(dst)
    if not s or not d:
        return False, f'could not resolve endpoints: src={src!r}->{s}, dst={dst!r}->{d}'
    if s == d:
        return True, f'{s} is the same endpoint as {d} (0 hops).'

    # ib_topology.json links use source_desc/target_desc (hostnames) + source_port/target_port.
    adj, edge = {}, {}
    for l in topo.get('links', []):
        a, b = l.get('source_desc'), l.get('target_desc')
        if not a or not b:
            continue
        adj.setdefault(a, set()).add(b)
        adj.setdefault(b, set()).add(a)
        edge[(a, b)] = (l.get('source_port', ''), l.get('target_port', ''), l.get('speed', ''))
        edge[(b, a)] = (l.get('target_port', ''), l.get('source_port', ''), l.get('speed', ''))

    from collections import deque
    prev = {s: None}
    q = deque([s])
    while q:
        cur = q.popleft()
        if cur == d:
            break
        for nb in sorted(adj.get(cur, ())):
            if nb not in prev:
                prev[nb] = cur
                q.append(nb)
    if d not in prev:
        return False, (f'NO PATH found between {s} and {d} in the discovered topology '
                       '(possible fabric partition or missing links).')

    path = []
    cur = d
    while cur is not None:
        path.append(cur)
        cur = prev[cur]
    path.reverse()
    lines = [f"PATH {s} -> {d} ({len(path) - 1} hops):"]
    for i in range(len(path) - 1):
        a, b = path[i], path[i + 1]
        sp, dp, spd = edge.get((a, b), ('', '', ''))
        lines.append(f"  {a} {sp} --[{spd}]--> {dp} {b}")
    return True, '\n'.join(lines)


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
            "(ollama / openai / claude / gemini / nvidia) and a model. The chat is "
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
    ) + "\n" + TOOL_INSTRUCTIONS
    
    # Build messages array
    messages = [{"role": "system", "content": system_prompt}]
    
    # Add conversation history (last 10 messages for context window)
    for msg in history[-10:]:
        messages.append({"role": msg.get('role', 'user'), "content": msg.get('content', '')})
    
    messages.append({"role": "user", "content": question})
    
    # Bounded read-only tool-calling loop. The model may emit [RUN: device command]
    # (Phase 2) or [RUNALL: target command] (Phase 3 parallel fan-out) to pull live
    # data; each call is executed via ib-api.sh run-device-command (its read-only
    # whitelist + admin auth + ssh exec are reused, not duplicated).
    cookie = os.environ.get('HTTP_COOKIE', '')
    valid_hostnames = {d.get('hostname', '') for d in devices.values() if d.get('hostname')}
    MAX_ROUNDS = 4
    MAX_TOOLS_PER_ROUND = 3
    MAX_TOTAL_TOOLS = 10
    MAX_DISPATCHES = 2            # [RUNALL: ...] parallel fan-outs per question
    DISPATCH_DEVICE_CAP = 120     # total switches across all dispatches
    deadline = time.time() + 220  # keep whole request under nginx's 300s read timeout
    total_tools = 0
    dispatches_used = 0
    dispatch_dev_total = 0
    response = ''
    tools_used = []

    for _round in range(MAX_ROUNDS):
        response = call_llm_sync(messages)
        runs = re.findall(r'\[RUN:\s*(\S+)\s+([^\]]+)\]', response or '')
        runalls = re.findall(r'\[RUNALL:\s*(\S+)\s+([^\]]+)\]', response or '')
        paths = re.findall(r'\[PATH:\s*(\S+)\s+(\S+)\]', response or '')
        if (not runs and not runalls and not paths) or time.time() > deadline:
            break
        results = []
        # Single-switch read-only tools
        for dev_name, cmd in runs[:MAX_TOOLS_PER_ROUND]:
            if total_tools >= MAX_TOTAL_TOOLS or time.time() > deadline:
                break
            dev_name = dev_name.strip()
            cmd = cmd.strip()
            if dev_name not in valid_hostnames:
                results.append(f"[{dev_name}] error: unknown switch (not in fabric)")
                continue
            ok, out = run_device_tool(dev_name, cmd, cookie)
            total_tools += 1
            tools_used.append({'device': dev_name, 'command': cmd, 'ok': ok})
            results.append(f"[RUN {dev_name}: {cmd}]\n{(out or '')[:6000]}")
        # Parallel multi-switch fan-out (Phase 3): at most one dispatch per round
        for tgt, cmd in runalls[:1]:
            if dispatches_used >= MAX_DISPATCHES or dispatch_dev_total >= DISPATCH_DEVICE_CAP or time.time() > deadline:
                break
            tgt = tgt.strip()
            cmd = cmd.strip()
            hosts, dres = run_dispatch(tgt, cmd, devices, cookie,
                                       max_devices=min(60, DISPATCH_DEVICE_CAP - dispatch_dev_total))
            dispatches_used += 1
            dispatch_dev_total += len(hosts)
            tools_used.append({'dispatch': tgt, 'command': cmd, 'devices': len(hosts)})
            lines = [f"[RUNALL {tgt}: {cmd}]  ({len(hosts)} switches, parallel)"]
            for h in hosts:
                ok, out = dres.get(h, (False, ''))
                lines.append(f"--- {h} [{'OK' if ok else 'FAIL'}] ---\n{out}")
            results.append('\n'.join(lines))
        # Topology path discovery (graph-based, read-only, no SSH)
        for src, dst in paths[:2]:
            if time.time() > deadline:
                break
            src, dst = src.strip(), dst.strip()
            ok, out = run_topology_path(src, dst)
            tools_used.append({'path': f'{src} -> {dst}', 'ok': ok})
            results.append(f"[PATH {src} -> {dst}]\n{out}")
        messages.append({"role": "assistant", "content": response})
        messages.append({"role": "user", "content":
            "TOOL RESULTS:\n" + "\n\n".join(results) +
            "\n\nContinue. Request more data only if needed; otherwise give the final answer with no [RUN: ...] / [RUNALL: ...] / [PATH: ...] lines."})

    # If still requesting tools (hit the round cap), force one final answer.
    if re.search(r'\[(?:RUN(?:ALL)?|PATH):', response or '') and time.time() < deadline:
        messages.append({"role": "assistant", "content": response})
        messages.append({"role": "user", "content":
            "Stop using tools. Give your final answer now from the results above; do not emit any data-tool lines ([RUN:]/[RUNALL:]/[PATH:]). You MAY include [FIX: ...] remediation suggestions."})
        response = call_llm_sync(messages)

    # Suggested remediation commands (NOT executed) -> returned as one-click buttons.
    fixes = []
    for dev, cmd in re.findall(r'\[FIX:\s*(\S+)\s+(.+?)\]', response or ''):
        fixes.append({'device': dev.strip(), 'command': cmd.strip()})

    # Strip leftover tool-call / fix lines from the visible answer (line-based: robust
    # even when a command in the marker contains ']').
    final = '\n'.join(
        ln for ln in (response or '').splitlines()
        if not re.search(r'\[(?:RUN(?:ALL)?|PATH|FIX):', ln)
    ).strip()

    result_json({"success": True, "response": final, "tools_used": tools_used, "fixes": fixes})


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


def action_report():
    """Generate a structured, printable IB fabric health report (markdown).
    Uses the same context as chat plus the ibdiagnet report, trend and UFM events."""
    if not AI_PROVIDER or not AI_MODEL:
        error_json("AI provider not configured. Set a provider in Settings first.")

    fabric_summary, devices, device_health = build_fabric_summary()
    device_list = build_device_list(devices, device_health)
    extra = []
    for _b in (build_ibdiag_context(), build_trend_context(), build_ufm_events_context()):
        if _b:
            extra.append(_b)
    extra_context = '\n\n'.join(extra)

    prompt = (
        "Produce a structured InfiniBand FABRIC HEALTH REPORT in GitHub-flavoured markdown.\n"
        "Use ONLY the data provided below; reference real hostnames, GUIDs, LIDs and ports.\n"
        "Do NOT invent values. Use these exact sections:\n\n"
        "# Fabric Health Report\n"
        "## Executive Summary  (2-4 sentences, end with overall status: RED / AMBER / GREEN)\n"
        "## Critical Issues  (bullets; if none, write 'None')\n"
        "## Warnings  (bullets; if none, write 'None')\n"
        "## Subnet Manager\n"
        "## Link Health & Trend\n"
        "## Partitions / QoS / SHARP\n"
        "## Transceivers & Hardware\n"
        "## Recommended Actions  (numbered, concrete MLNX-OS commands or LLDPq-IB pages)\n\n"
        "=== DATA ===\n"
        f"{fabric_summary}\n\n{device_list}\n\n{extra_context}\n=== END ==="
    )
    messages = [
        {"role": "system", "content": "You are an InfiniBand fabric health auditor. "
         "Output ONLY the markdown report, no preamble."},
        {"role": "user", "content": prompt},
    ]
    report = call_llm_sync(messages)
    result_json({"success": True, "report": report, "timestamp": time.time(),
                 "device_count": len(devices)})


def action_get_audit():
    """Return the most recent AI live-command executions (admin only)."""
    entries = []
    for path in (os.path.join(WEB_ROOT, 'monitor-results', 'ai-audit.log'),
                 '/tmp/lldpq-ai-audit.log'):
        if os.path.exists(path):
            try:
                with open(path) as f:
                    for ln in f.readlines()[-200:]:
                        try:
                            entries.append(json.loads(ln))
                        except Exception:
                            pass
            except Exception:
                pass
            break
    entries.reverse()
    result_json({"success": True, "entries": entries})


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
elif ACTION == 'report':
    action_report()
elif ACTION == 'get-audit':
    action_get_audit()
elif ACTION == 'get-log-messages':
    try:
        totals, messages = _load_ib_logs()
        result_json({"success": True, "messages": messages, "totals": totals})
    except Exception as e:
        error_json(str(e))
else:
    error_json(f"Unknown action: {ACTION}")

PYTHON_SCRIPT
