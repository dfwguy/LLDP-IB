#!/usr/bin/env bash
# LLDPq-IB API endpoint
# Handles device CRUD/list and safe MLNX-OS command execution.
# Replacement for Cumulus LLDPq's fabric-api.sh.
#
# Copyright (c) 2024-2026 LLDPq Project - Licensed under MIT License

set -uo pipefail

# Allow nginx/fcgiwrap to authenticate the request via shared session cookie.
source /var/www/html/auth-guard.sh 2>/dev/null || true

# Require admin for most actions; ansible-status + list-devices allowed for operators.
ACTION="${QUERY_STRING#*action=}"
ACTION="${ACTION%%&*}"
case "$ACTION" in
    ansible-status|list-devices) ;;
    *)
        if ! ${AUTH_REQUIRE_ADMIN:-false}; then
            require_admin 2>/dev/null || true
        fi
        ;;
esac

echo "Content-Type: application/json"
echo ""

source /etc/lldpq.conf 2>/dev/null || true
LLDPQ_DIR="${LLDPQ_DIR:-/home/lldpq/lldpq}"

case "$ACTION" in
    # -------------------------------------------------------------------
    # ansible-status: LLDPq-IB has no Ansible, so always return "not configured".
    # Index.html uses this to hide/show the Ansible sidebar group; we want it
    # hidden permanently.
    # -------------------------------------------------------------------
    ansible-status)
        echo '{"configured": false, "ansible_dir": "", "edition": "infiniband"}'
        ;;

    # -------------------------------------------------------------------
    # list-devices: returns devices.yaml as a grouped list (by role).
    # -------------------------------------------------------------------
    list-devices)
        python3 << 'PYTHON_END'
import json
import os

devices_file = os.environ.get('LLDPQ_DIR', '/home/lldpq/lldpq') + '/devices.yaml'

try:
    import yaml
    with open(devices_file, 'r') as f:
        data = yaml.safe_load(f) or {}
except Exception as e:
    print(json.dumps({'success': False, 'error': f'Cannot read devices.yaml: {e}'}))
    raise SystemExit

defaults = data.get('defaults', {})
default_user = defaults.get('username', 'admin')
devices = data.get('devices', {})

groups = {}
flat = []
for ip, val in devices.items():
    hostname = ''
    role = ''
    user = default_user
    if isinstance(val, str):
        # "Hostname @role" or just "Hostname"
        parts = val.strip().split()
        if parts:
            hostname = parts[0]
            for p in parts[1:]:
                if p.startswith('@'):
                    role = p[1:]
    elif isinstance(val, dict):
        hostname = val.get('hostname', '')
        role = val.get('role', '')
        user = val.get('username', default_user)
    if not hostname:
        continue
    entry = {'hostname': hostname, 'ip': ip, 'role': role or 'switch', 'username': user}
    flat.append(entry)
    groups.setdefault(entry['role'], []).append(entry)

# Sort each group by hostname
for r in groups:
    groups[r].sort(key=lambda d: d['hostname'])

print(json.dumps({
    'success': True,
    'devices': groups,           # grouped by role (for sidebar device list)
    'devices_flat': flat,        # flat list (for search etc.)
    'ansible_dir': '',           # IB edition does not use Ansible
}))
PYTHON_END
        ;;

    # -------------------------------------------------------------------
    # get-device: return basic device info (host_vars equivalent does not
    # exist in IB edition; we just return cached assets.ini data + a stub
    # config object for backward compatibility with device.html).
    # -------------------------------------------------------------------
    get-device)
        HOSTNAME_ARG="${QUERY_STRING#*hostname=}"
        HOSTNAME_ARG="${HOSTNAME_ARG%%&*}"
        export HOSTNAME_ARG
        python3 << 'PYTHON_END'
import json
import os

hostname = os.environ.get('HOSTNAME_ARG', '')
lldpq_dir = os.environ.get('LLDPQ_DIR', '/home/lldpq/lldpq')

result = {
    'success': True,
    'hostname': hostname,
    'config': {},
    'device_info': {'hostname': hostname, 'ip': None, 'group': None},
    'port_profiles': {},
    'vlan_to_vrf': {},
    'vlan_profiles': {},
    'vxlan_int_mapping': {},
}

# Try to look up the device in assets.ini for IP + model info
assets_file = lldpq_dir + '/assets.ini'
if os.path.exists(assets_file):
    try:
        with open(assets_file, 'r') as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith('#'):
                    continue
                parts = line.split('\t')
                if not parts:
                    continue
                if parts[0] == hostname:
                    # Fields: hostname IP model serial release os uptime
                    if len(parts) > 1: result['device_info']['ip'] = parts[1]
                    if len(parts) > 2: result['device_info']['model'] = parts[2]
                    if len(parts) > 3: result['device_info']['serial'] = parts[3]
                    if len(parts) > 4: result['device_info']['release'] = parts[4]
                    break
    except Exception:
        pass

print(json.dumps(result))
PYTHON_END
        ;;

    # -------------------------------------------------------------------
    # get-device-data: aggregated dashboard data for device.html overview.
    # We synthesize a minimal payload from JSON files written by the IB
    # parsers (transceiver/optical/logs/etc.).
    # -------------------------------------------------------------------
    get-device-data)
        DEVICE="${QUERY_STRING#*device=}"
        DEVICE="${DEVICE%%&*}"
        # URL decode %20 -> space (very minimal; hostnames should not have spaces)
        DEVICE=$(echo "$DEVICE" | sed 's/%20/ /g')
        export DEVICE
        python3 << 'PYTHON_END'
import json
import os

device = os.environ.get('DEVICE', '')
result = {
    'success': True,
    'device': device,
    'optical': [],
    'logs': {'critical': 0, 'warning': 0, 'error': 0, 'info': 0},
    'last_update': None,
}

# Best effort: read transceiver inventory + log summary
mr = '/var/www/html/monitor-results'
try:
    with open(f'{mr}/transceiver_inventory.json', 'r') as f:
        tx = json.load(f)
    device_modules = [m for m in tx.get('modules', []) if m.get('device') == device]
    for m in device_modules:
        state = str(m.get('health') or '').lower()
        result['optical'].append({
            'port': m.get('port'),
            'health': 'down' if state == 'down' else 'ok',
            'identifier': m.get('identifier'),
            'part_number': m.get('part_number'),
            'serial_number': m.get('serial_number'),
            'fw_version': m.get('fw_version'),
            'temperature': m.get('temperature'),
            'technology': m.get('technology'),
            'vendor': m.get('vendor'),
        })
except Exception:
    pass

print(json.dumps(result))
PYTHON_END
        ;;

    # -------------------------------------------------------------------
    # run-device-command: SSH a safe MLNX-OS command to the device.
    # Whitelist is strict: only 'show ...', 'ib ...', and a handful of safe
    # shell commands are allowed. Pipes to grep/head/tail/awk/sed/wc/cut/sort
    # are permitted (read-only filtering).
    # -------------------------------------------------------------------
    run-device-command)
        read -r POST_DATA
        export POST_DATA
        python3 << 'PYTHON_END'
import json
import subprocess
import re
import os
import fcntl

post_data = os.environ.get('POST_DATA', '{}')
try:
    params = json.loads(post_data)
except Exception:
    params = {}

device = params.get('device', '')
command = params.get('command', '').strip()

if not device or not command:
    print(json.dumps({'success': False, 'error': 'Missing device or command'}))
    raise SystemExit

if any(ord(ch) < 32 for ch in command):
    print(json.dumps({'success': False, 'error': 'Command contains control characters'}))
    raise SystemExit

# -------- Forbidden patterns (write operations, dangerous flows) ------
FORBIDDEN_PATTERNS = [
    r'\breboot\b',
    r'\bshutdown\b',
    r'\bwrite\s+memory\b',
    r'\bwrite\s+terminal\b',
    r'\bcopy\b',                 # MLNX-OS file copy
    r'\bdelete\b',
    r'\benable\s+mode',           # only-show, not enable-only
    r'\bconfigure\s+terminal\b',  # no config mode
    r'\bib\s+sm\s+stop\b',
    r'\bib\s+sm\s+start\b',
    r'\bib\s+sm\s+disable\b',
    r'\bib\s+sm\s+enable\b',
    r'\bmlxfwmanager\b',          # firmware upgrade tools
    r'\bflint\b',
]
for p in FORBIDDEN_PATTERNS:
    if re.search(p, command, re.IGNORECASE):
        print(json.dumps({'success': False, 'error': 'Command is not allowed from Device Details'}))
        raise SystemExit

# -------- Allowed top-level patterns (left side of any pipe) ----------
ALLOWED_PATTERNS = [
    r'^show\b',                # MLNX-OS native show commands
    r'^ib\s+\w+',               # ibutils via CLI prefix (ib sminfo, ib perfquery, ...)
    r'^ip\s+(?:link|addr|route|neigh)\b',  # Linux shell allowed reads
    r'^uptime$',
    r'^free(\s|$)',
    r'^df(\s|$)',
    r'^cat\s+/var/log/',
    r'^tail\s+(?:-n\s+\d+\s+)?/var/log/',
    r'^journalctl\b',
    r'^dmesg\b',
]

# Split on pipe; left-side must match an allowed pattern, right-side filters
parts = [p.strip() for p in command.split('|')]
left = parts[0]
allowed = any(re.match(p, left, re.IGNORECASE) for p in ALLOWED_PATTERNS)
if not allowed:
    print(json.dumps({
        'success': False,
        'error': 'Command not in whitelist. Allowed: show ..., ib ..., ip link/addr/route/neigh, uptime, free, df, journalctl, dmesg, tail/cat /var/log/...',
    }))
    raise SystemExit

# Right-side filters (read-only)
FILTER_WHITELIST = re.compile(r'^(?:grep|head|tail|wc|awk|sed|sort|uniq|cut|tr|column)(\s|$)')
for piece in parts[1:]:
    if not FILTER_WHITELIST.match(piece):
        print(json.dumps({'success': False, 'error': f'Pipe to non-readonly command rejected: {piece.split()[0] if piece else ""}'}))
        raise SystemExit

# -------- Injection check on the whole command --------
# Pipes are explicitly allowed; we still forbid `;&` and command substitution.
INJECTION_PATTERNS = [r'[;&`\$]', r'>>', r'<<', r'[\r\n]']
for p in INJECTION_PATTERNS:
    if re.search(p, command):
        print(json.dumps({'success': False, 'error': 'Command contains unsafe characters'}))
        raise SystemExit

# -------- Look up device IP and SSH user from devices.yaml ----------
lldpq_dir = os.environ.get('LLDPQ_DIR', '/home/lldpq/lldpq')
devices_file = lldpq_dir + '/devices.yaml'

device_ip = None
ssh_user = 'admin'  # MLNX-OS default
try:
    import yaml
    with open(devices_file, 'r') as f:
        data = yaml.safe_load(f) or {}
    defaults = data.get('defaults', {})
    ssh_user = defaults.get('username', 'admin')
    for ip, val in (data.get('devices', {}) or {}).items():
        hostname = ''
        if isinstance(val, str):
            hostname = val.strip().split()[0] if val.strip() else ''
        elif isinstance(val, dict):
            hostname = val.get('hostname', '')
            if val.get('username'):
                ssh_user = val['username']
        if hostname == device:
            device_ip = ip
            break
except Exception as e:
    print(json.dumps({'success': False, 'error': f'Cannot resolve device: {e}'}))
    raise SystemExit

if not device_ip:
    print(json.dumps({'success': False, 'error': f'Unknown device: {device}'}))
    raise SystemExit

# -------- Validate device name + IP --------
if not re.match(r'^[a-zA-Z0-9][a-zA-Z0-9\-.]*[a-zA-Z0-9]$', device):
    print(json.dumps({'success': False, 'error': 'Invalid device name'}))
    raise SystemExit
if not re.match(r'^[a-fA-F0-9.:]+$', device_ip):
    print(json.dumps({'success': False, 'error': 'Invalid device IP'}))
    raise SystemExit

# -------- Per-device lock to avoid SSH thundering herd --------
lock_dir = '/tmp/lldpq-ib-locks'
os.makedirs(lock_dir, exist_ok=True)
lock_path = f"{lock_dir}/{device}.lock"
lock_fp = open(lock_path, 'w')
try:
    fcntl.flock(lock_fp, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    print(json.dumps({'success': False, 'error': 'Another command is running on this device'}))
    raise SystemExit

# -------- Execute via interactive enable-mode CLI --------
# MLNX-OS admin accounts are CLI-only: `ssh host "cmd"` (exec) is rejected with
# "UNIX shell commands cannot be executed using this account". So we open an
# interactive enable-mode session over key auth, feed the command on stdin, then
# strip the login banner + prompt echoes so the caller sees just the output.
LLDPQ_USER = os.environ.get('LLDPQ_USER', 'lldpq')
cli_input = f"enable\nno cli session paging enable\n{command}\nexit\nexit\n"
try:
    result = subprocess.run(
        ['sudo', '-u', LLDPQ_USER, 'timeout', '60',
         'ssh', '-tt', '-o', 'StrictHostKeyChecking=no', '-o', 'BatchMode=yes',
         '-o', 'UserKnownHostsFile=/dev/null', '-o', 'LogLevel=ERROR',
         '-o', 'ConnectTimeout=10',
         f'{ssh_user}@{device_ip}'],
        input=cli_input, capture_output=True, text=True, timeout=75,
    )
    raw = (result.stdout or '').replace('\r', '')
    prompt_re = re.compile(r'^\S+\s+\[[^\]]*\]\s+[>#]')  # "host [standalone: master] > cmd"
    skip_prefix = ('Last login', 'Last failed login', 'There was ', 'There were ',
                   'Number of total', 'Connection to ', 'Warning: Permanently added')
    banners = ('NVIDIA Switch', 'NVIDIA MLNX-OS Switch Management')
    # control lines = what we typed; the tty raw-echoes them before the shell runs
    control = {'enable', 'no cli session paging enable', 'exit', command.strip()}
    cleaned = []
    for ln in raw.split('\n'):
        s = ln.rstrip()
        st = s.strip()
        if prompt_re.match(s):                 # prompt-prefixed echoes
            continue
        if st in control or st in banners:     # raw command echoes + login banner
            continue
        if s.startswith(skip_prefix):
            continue
        cleaned.append(s)
    output = '\n'.join(cleaned).strip()
    if not output and result.stderr:
        output = result.stderr.strip()
    print(json.dumps({
        'success': True,
        'device': device,
        'command': command,
        'output': output,
        'exit_code': result.returncode,
    }))
except subprocess.TimeoutExpired:
    print(json.dumps({'success': False, 'error': 'Command timed out'}))
except Exception as e:
    print(json.dumps({'success': False, 'error': str(e)}))
finally:
    try:
        fcntl.flock(lock_fp, fcntl.LOCK_UN)
    except Exception:
        pass
    lock_fp.close()
PYTHON_END
        ;;

    # -------------------------------------------------------------------
    # ibtracert: run `ib ibtracert -G <src_guid> <dst_guid>` from the
    # first reachable switch in devices.yaml. Parses the hop-by-hop output
    # back into the {to_guid, lp, rp, speed} array shape that the BFS path
    # in tracepath.html consumes.
    # Body: JSON { src_guid: "0x...", dst_guid: "0x..." }
    # -------------------------------------------------------------------
    ibtracert)
        read -r POST_DATA 2>/dev/null || true
        # Live ibtracert needs switch-side ib* utilities, which CLI-only MLNX-OS
        # does NOT expose (the `ib` keyword is an ibdiagnet wrapper, and SSH exec
        # is rejected). The Tracepath UI falls back to topology BFS on this reply.
        echo '{"success": false, "error": "Live ibtracert is unavailable on CLI-only MLNX-OS switches; using topology BFS instead. For live routing run the Fabric Diagnostic (ibdiagnet) on the UFM appliance."}'
        ;;

    ibtracert-legacy-disabled)
        read -r POST_DATA
        export POST_DATA
        python3 << 'PYTHON_END'
import json, os, re, subprocess

try:
    body = json.loads(os.environ.get('POST_DATA') or '{}')
except Exception:
    body = {}
src = (body.get('src_guid') or '').strip()
dst = (body.get('dst_guid') or '').strip()
if not re.match(r'^0x[0-9a-fA-F]{12,16}$', src) or not re.match(r'^0x[0-9a-fA-F]{12,16}$', dst):
    print(json.dumps({'success': False, 'error': 'src_guid and dst_guid must be 0x-prefixed hex'}))
    raise SystemExit

LLDPQ_DIR = os.environ.get('LLDPQ_DIR', '/home/lldpq/lldpq')

# Pick the first reachable switch (assets.ini) -- if none, bail out.
import os.path
asset_paths = ['/var/www/html/assets.ini', os.path.join(LLDPQ_DIR, 'assets.ini')]
switch_host = None
for ap in asset_paths:
    if not os.path.exists(ap):
        continue
    try:
        with open(ap) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith('#'):
                    continue
                parts = line.split('\t')
                if len(parts) >= 1 and parts[0]:
                    switch_host = parts[0]
                    break
        if switch_host:
            break
    except Exception:
        pass
if not switch_host:
    print(json.dumps({'success': False,
        'error': 'No reachable switch in assets.ini -- cannot run ibtracert. '
                 'Switch back to BFS mode, or run ib-monitor.sh once.'}))
    raise SystemExit

LLDPQ_USER = os.environ.get('LLDPQ_USER', 'lldpq')
remote_cmd = f'ib ibtracert -G {src} {dst}'
try:
    r = subprocess.run(
        ['sudo', '-u', LLDPQ_USER, 'ssh',
         '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8',
         '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=/dev/null',
         '-o', 'LogLevel=ERROR', f'admin@{switch_host}', remote_cmd],
        capture_output=True, text=True, timeout=25,
    )
except subprocess.TimeoutExpired:
    print(json.dumps({'success': False, 'error': 'ibtracert timed out'}))
    raise SystemExit
except Exception as e:
    print(json.dumps({'success': False, 'error': f'SSH error: {e}'}))
    raise SystemExit

if r.returncode != 0:
    print(json.dumps({'success': False,
        'error': f'ibtracert exited {r.returncode}: ' + (r.stderr or r.stdout)[:300]}))
    raise SystemExit

# ibtracert output format (one block per hop):
#   From <type> {0x..lguid..} portnum N lid <L>
#   [N] -> <type> port {0x..nguid..}[M] lid <L>
hop_re = re.compile(
    r'-\>\s+\w+\s+port\s+\{(?P<guid>0x[0-9a-fA-F]+)\}\[(?P<rp>\d+)\]',
    re.IGNORECASE,
)
out_re = re.compile(r'\[(?P<lp>\d+)\]\s+->', re.IGNORECASE)

hops = []
local_port = None
for line in r.stdout.splitlines():
    m_out = out_re.search(line)
    if m_out:
        local_port = int(m_out.group(1))
    m_hop = hop_re.search(line)
    if m_hop:
        hops.append({
            'to_guid': m_hop.group('guid'),
            'lp':      local_port,
            'rp':      int(m_hop.group('rp')),
            'speed':   '',     # ibtracert does not include speed
        })
        local_port = None

print(json.dumps({
    'success': True,
    'via_switch': switch_host,
    'src_guid': src,
    'dst_guid': dst,
    'hop_count': len(hops),
    'path': hops,
    'raw': r.stdout[-1000:],   # truncate raw text
}))
PYTHON_END
        ;;

    *)
        echo "{\"success\": false, \"error\": \"Unknown action: ${ACTION}\"}"
        ;;
esac
