#!/usr/bin/env bash
# diag-api.sh - Fabric Diagnostic (ibdiagnet) runner API.
#
# Drives the on-demand "Fabric Diagnostic" builder on diagnostics.html and serves
# the parsed results. The heavy lifting (run -> parse -> discard -> retain) is done
# by lldpq/run-ibdiagnet.sh, which this endpoint launches detached in the
# background so the request returns immediately and the UI polls for status.
#
# Actions:
#   GET  ?action=last            -> latest parsed summary (ib_fabric_diag.json)
#   GET  ?action=runs            -> run index (history)
#   GET  ?action=status&run=ID   -> status of a specific run (poll target)
#   GET  ?action=targets         -> selectable targets (devices + configured UFM host)
#   POST ?action=run             -> start a run; body = {target, bin, flags:{...}}
#
# Admin only. Flags are built from a fixed whitelist (never raw passthrough), and
# the target must resolve to a known device or the configured UFM SSH host.
#
# Copyright (c) 2024-2026 LLDPq Project - Licensed under MIT License

source /var/www/html/auth-guard.sh 2>/dev/null || true
require_admin

echo "Content-Type: application/json"
echo ""

source /etc/lldpq.conf 2>/dev/null || true
export LLDPQ_DIR="${LLDPQ_DIR:-/home/lldpq/lldpq}"
export WEB_ROOT="${WEB_ROOT:-/var/www/html}"
# Export UFM/ibdiagnet settings so the python blocks (os.environ) can read them
# (source sets shell vars, which are NOT inherited by subprocesses unless exported).
export UFM_SSH_HOST="${UFM_SSH_HOST:-}" UFM_SSH_USER="${UFM_SSH_USER:-root}"
export IBDIAGNET_DOCKER="${IBDIAGNET_DOCKER:-}" IBDIAGNET_BIN="${IBDIAGNET_BIN:-}"
RUNS_DIR="$WEB_ROOT/monitor-results/ibdiag-runs"

ACTION="${QUERY_STRING#*action=}"
ACTION="${ACTION%%&*}"

case "$ACTION" in
    last)
        cat "$WEB_ROOT/monitor-results/ib_fabric_diag.json" 2>/dev/null \
            || echo '{"parsed": false, "message": "No fabric diagnostic has been run yet."}'
        ;;

    runs)
        cat "$RUNS_DIR/index.json" 2>/dev/null || echo '[]'
        ;;

    status)
        RUN="${QUERY_STRING#*run=}"
        RUN="${RUN%%&*}"
        RUN=$(printf '%s' "$RUN" | tr -cd 'A-Za-z0-9TZ_-')
        cat "$RUNS_DIR/${RUN}.status" 2>/dev/null \
            || echo '{"state": "unknown", "message": "No such run."}'
        ;;

    targets)
        # ibdiagnet needs the ibdiagnet BINARY + IB access on the target. MLNX-OS
        # switches are CLI-only and cannot run it, so they are intentionally NOT
        # offered here (selecting one would always fail). Valid targets: a locally
        # installed ibdiagnet (if the image ships it) or the configured UFM SSH
        # appliance. For routine fabric health use the Local Fabric Scan instead.
        HAS_LOCAL_IBDIAGNET="no"
        command -v ibdiagnet >/dev/null 2>&1 && HAS_LOCAL_IBDIAGNET="yes"
        export HAS_LOCAL_IBDIAGNET
        python3 <<'PY'
import json, os
targets = []
if os.environ.get('HAS_LOCAL_IBDIAGNET') == 'yes':
    targets.append({'id': 'localhost', 'label': 'This container (local ibdiagnet, direct IB)',
                    'kind': 'local', 'user': ''})
ufm_host = os.environ.get('UFM_SSH_HOST', '')
if ufm_host:
    targets.append({'id': 'ufm', 'label': f'UFM appliance ({ufm_host})', 'kind': 'ufm',
                    'user': os.environ.get('UFM_SSH_USER', 'root')})
print(json.dumps({
    'success': True,
    'targets': targets,
    'ufm_configured': bool(ufm_host),
    'local_ibdiagnet': os.environ.get('HAS_LOCAL_IBDIAGNET') == 'yes',
}))
PY
        ;;

    delete)
        # Delete one diagnostic run (json + status + raw archive) and drop it from
        # the index. The runs dir is group-writable (lldpq:www-data), so the CGI
        # user can remove without sudo.
        RUN="${QUERY_STRING#*run=}"
        RUN="${RUN%%&*}"
        RUN=$(printf '%s' "$RUN" | tr -cd 'A-Za-z0-9TZ_-')
        if [ -z "$RUN" ]; then
            echo '{"success": false, "error": "No run id"}'
            exit 0
        fi
        # Runs live in BOTH the web dir (served) and the working dir (source of
        # truth that run-ibdiagnet re-publishes). Clean both, or a later run's
        # publish resurrects the deleted entry. The working dir is root-owned, so
        # remove the files via sudo (www-data has a NOPASSWD rm rule).
        WORK_RUNS="$LLDPQ_DIR/monitor-results/ibdiag-runs"
        for d in "$RUNS_DIR" "$WORK_RUNS"; do
            sudo rm -f "$d/${RUN}.json" "$d/${RUN}.status" "$d/${RUN}.run.log" "$d/${RUN}.tar.gz" 2>/dev/null
        done
        export DEL_RUN="$RUN" DEL_DIRS="$RUNS_DIR:$WORK_RUNS"
        python3 <<'PY'
import json, os
run_id = os.environ['DEL_RUN']
removed = 0
for runs_dir in os.environ['DEL_DIRS'].split(':'):
    idx = os.path.join(runs_dir, 'index.json')
    if not os.path.exists(idx):
        continue
    try:
        data = json.load(open(idx))
    except Exception:
        data = []
    before = len(data)
    data = [e for e in data if e.get('run_id') != run_id]
    removed += before - len(data)
    try:
        with open(idx, 'w') as f:
            json.dump(data, f, indent=2)
    except Exception:
        pass
print(json.dumps({'success': True, 'deleted': run_id, 'removed': removed}))
PY
        ;;

    local-scan)
        # Direct in-container IB fabric scan via local ibutils (no switch SSH, no
        # ibdiagnet bundle). UMAD is root-only, so run via sudo. The container must
        # be --privileged --network host on an IB-connected node.
        OUT=$(sudo -n "$LLDPQ_DIR/ib-local-scan.sh" 2>/dev/null)
        if printf '%s' "$OUT" | grep -q '"success": true'; then
            printf '%s\n' "$OUT"
        else
            echo '{"success": false, "error": "Local scan failed. Needs direct container IB (UMAD) access and the ib-local-scan sudo rule. Confirm the container runs --privileged --network host on an IB-connected node."}'
        fi
        ;;

    ufm-ssh-setup)
        # POST {host, user, password, container, bin} -> install the collector key
        # on the UFM appliance host and wire ibdiagnet-via-docker. The push runs
        # AS lldpq (collector-key owner) via sudo.
        if [ "${REQUEST_METHOD:-GET}" != "POST" ]; then
            echo '{"success": false, "error": "POST required"}'; exit 0
        fi
        read -r POST_DATA
        export POST_DATA
        _field() { python3 -c 'import json,os,sys; print(str(json.loads(os.environ.get("POST_DATA") or "{}").get(sys.argv[1],"") or ""))' "$1" 2>/dev/null; }
        U_HOST=$(_field host); U_USER=$(_field user); U_PW=$(_field password)
        U_CT=$(_field container); U_BIN=$(_field bin)
        if [ -z "$U_HOST" ] || [ -z "$U_PW" ]; then
            echo '{"success": false, "error": "host and password are required"}'; exit 0
        fi
        ARGS=(-h "$U_HOST" -p "$U_PW")
        [ -n "$U_USER" ] && ARGS+=(-u "$U_USER")
        [ -n "$U_CT" ]   && ARGS+=(-c "$U_CT")
        [ -n "$U_BIN" ]  && ARGS+=(-b "$U_BIN")
        OUT=$(sudo -u "$LLDPQ_USER" -H "$LLDPQ_DIR/setup-ufm-ssh.sh" "${ARGS[@]}" 2>/dev/null)
        if printf '%s' "$OUT" | grep -q '"success"'; then
            printf '%s\n' "$OUT"
        else
            echo '{"success": false, "error": "setup-ufm-ssh.sh produced no result (sudo rule / script present?)"}'
        fi
        ;;

    run)
        if [ "${REQUEST_METHOD:-GET}" != "POST" ]; then
            echo '{"success": false, "error": "run requires POST"}'
            exit 0
        fi
        read -r POST_DATA
        export POST_DATA
        python3 <<'PY'
import json, os, re, subprocess
from datetime import datetime, timezone

lldpq_dir = os.environ.get('LLDPQ_DIR', '/home/lldpq/lldpq')
web_root  = os.environ.get('WEB_ROOT', '/var/www/html')
runs_dir  = os.path.join(web_root, 'monitor-results', 'ibdiag-runs')

try:
    body = json.loads(os.environ.get('POST_DATA') or '{}')
except Exception:
    body = {}

target_id = str(body.get('target', '')).strip()
if not target_id:
    print(json.dumps({'success': False, 'error': 'No target selected'}))
    raise SystemExit

# ---- Resolve target against devices.yaml / configured UFM host ----
resolved_host = None
ssh_user = 'admin'
ufm_host = os.environ.get('UFM_SSH_HOST', '')
ufm_user = os.environ.get('UFM_SSH_USER', 'root')

if target_id == 'ufm':
    if not ufm_host:
        print(json.dumps({'success': False,
            'error': 'UFM SSH host not configured. Set UFM_SSH_HOST (and UFM_SSH_USER) to run ibdiagnet on the UFM appliance.'}))
        raise SystemExit
    resolved_host, ssh_user = ufm_host, ufm_user
else:
    try:
        import yaml
        data = yaml.safe_load(open(lldpq_dir + '/devices.yaml')) or {}
        defaults = data.get('defaults', {})
        duser = defaults.get('username', 'admin')
        for ip, val in (data.get('devices', {}) or {}).items():
            host = ''
            user = duser
            if isinstance(val, str):
                parts = val.strip().split()
                host = parts[0] if parts else ''
            elif isinstance(val, dict):
                host = val.get('hostname', '')
                user = val.get('username', duser)
            if host == target_id:
                resolved_host, ssh_user = ip, user
                break
    except Exception as e:
        print(json.dumps({'success': False, 'error': f'Cannot read devices.yaml: {e}'}))
        raise SystemExit

if not resolved_host:
    print(json.dumps({'success': False, 'error': f'Unknown target: {target_id}'}))
    raise SystemExit

# ---- Binary (limited choices) ----
bin_choice = str(body.get('bin', '')).strip()
ALLOWED_BINS = {'ibdiagnet', '/opt/ufm/opensm/bin/ibdiagnet'}
if bin_choice not in ALLOWED_BINS:
    bin_choice = '/opt/ufm/opensm/bin/ibdiagnet' if target_id == 'ufm' else 'ibdiagnet'

# ---- Build flags from a fixed whitelist (no raw passthrough) ----
flags = []
BOOL_FLAGS = {
    'routing': '--routing',
    'ft': '--ft',
    'get_phy_info': '--get_phy_info',
    'rail_validation': '--rail_validation',
    'sc': '--sc',
    'pm_per_lane': '--pm_per_lane',
    'get_cable_info': '--get_cable_info',
}
fl = body.get('flags', {}) or {}
for key, flag in BOOL_FLAGS.items():
    if fl.get(key):
        flags.append(flag)
if fl.get('extended_speeds'):
    flags += ['--extended_speeds', 'all']
if fl.get('pm_all'):
    flags += ['-P', 'all=1']

def clamp_int(val, lo, hi, default):
    try:
        v = int(val)
    except Exception:
        return default
    return max(lo, min(hi, v))

if fl.get('mads_timeout') is not None:
    flags += ['--mads_timeout', str(clamp_int(fl.get('mads_timeout'), 100, 60000, 2000))]
if fl.get('mads_retries') is not None:
    flags += ['--mads_retries', str(clamp_int(fl.get('mads_retries'), 1, 20, 3))]
if fl.get('pm_pause_time') is not None:
    flags += ['--pm_pause_time', str(clamp_int(fl.get('pm_pause_time'), 0, 7200, 1200))]

KNOWN_OUTPUTS = ['log', 'lst', 'sm', 'pm', 'iblinkinfo', 'fdbs', 'ar', 'far', 'slvl', 'rnc2', 'cables']
outs = [o for o in (fl.get('enable_output') or []) if o in KNOWN_OUTPUTS]
if outs:
    flags += ['--enable_output', ','.join(outs)]

flag_str = ' '.join(flags)
# Final safety net: only the safe ibdiagnet flag charset, and never -o.
if flag_str and re.search(r'[^A-Za-z0-9 _,=./-]', flag_str):
    print(json.dumps({'success': False, 'error': 'Internal: unsafe flag string built'}))
    raise SystemExit
if ' -o ' in f' {flag_str} ':
    print(json.dumps({'success': False, 'error': 'Output path is managed; -o not allowed'}))
    raise SystemExit

# ---- Generate run id + initial status, then launch the runner detached ----
run_id = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
os.makedirs(runs_dir, exist_ok=True)
now = datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC')
try:
    with open(os.path.join(runs_dir, f'{run_id}.status'), 'w') as f:
        json.dump({'run_id': run_id, 'state': 'queued',
                   'message': f'Queued ibdiagnet on {target_id}',
                   'target': target_id, 'started_at': now, 'updated_at': now}, f)
except Exception as e:
    print(json.dumps({'success': False, 'error': f'Cannot create status file: {e}'}))
    raise SystemExit

env = dict(os.environ)
env['IBDIAG_TARGET'] = resolved_host
env['IBDIAG_USER']   = ssh_user
env['IBDIAG_BIN']    = bin_choice
env['IBDIAG_FLAGS']  = flag_str
env['IBDIAG_RUN_ID'] = run_id
# UFM Enterprise runs ibdiagnet inside a container; wrap the run in docker exec.
if target_id == 'ufm':
    env['IBDIAG_DOCKER'] = os.environ.get('IBDIAGNET_DOCKER', 'ufm')

runner = os.path.join(lldpq_dir, 'run-ibdiagnet.sh')
try:
    devnull = open(os.devnull, 'w')
    subprocess.Popen(['bash', runner], env=env,
                     stdout=devnull, stderr=subprocess.STDOUT,
                     start_new_session=True)
except Exception as e:
    print(json.dumps({'success': False, 'error': f'Failed to launch runner: {e}'}))
    raise SystemExit

print(json.dumps({
    'success': True,
    'run_id': run_id,
    'target': target_id,
    'command': f'{bin_choice} {flag_str} -o <managed>',
}))
PY
        ;;

    get-schedule)
        # Report the current periodic ibdiagnet schedule (from the lldpq user crontab).
        python3 <<'PY'
import json, os, re, subprocess
try:
    r = subprocess.run(['sudo', '-n', '-u', 'lldpq', 'bash', '-c', 'crontab -l 2>/dev/null'],
                       capture_output=True, text=True, timeout=10)
    txt = r.stdout or ''
except Exception:
    txt = ''
line = next((l for l in txt.splitlines() if 'run-ibdiagnet.sh' in l and not l.strip().startswith('#')), '')
hours, target = 0, ''
if line:
    parts = line.split()
    if len(parts) >= 5:
        minute, hour = parts[0], parts[1]
        if hour.startswith('*/'):
            try: hours = int(hour[2:])
            except Exception: hours = 0
        elif hour == '*':
            hours = 1
        elif hour == '0' and minute == '0':
            hours = 24
    m = re.search(r"IBDIAG_TARGET='([^']*)'", line)
    target = m.group(1) if m else ''
print(json.dumps({'success': True, 'hours': hours, 'target': target}))
PY
        ;;

    set-schedule)
        if [ "${REQUEST_METHOD:-GET}" != "POST" ]; then
            echo '{"success": false, "error": "set-schedule requires POST"}'
            exit 0
        fi
        read -r POST_DATA
        export POST_DATA
        python3 <<'PY'
import json, os, re, shlex, subprocess

ALLOWED_HOURS = {0, 1, 2, 3, 4, 6, 12, 24}
lldpq_dir = os.environ.get('LLDPQ_DIR', '/home/lldpq/lldpq')

try:
    body = json.loads(os.environ.get('POST_DATA') or '{}')
except Exception:
    body = {}
try:
    hours = int(body.get('hours', 0))
except Exception:
    hours = -1
if hours not in ALLOWED_HOURS:
    print(json.dumps({'success': False, 'error': 'Invalid interval (allowed: 0,1,2,3,4,6,12,24h)'}))
    raise SystemExit

target_id = str(body.get('target', '')).strip()

def install(cron_line):
    if cron_line:
        inner = ('( crontab -l 2>/dev/null | grep -v run-ibdiagnet.sh; '
                 f'echo {shlex.quote(cron_line)} ) | crontab -')
    else:
        inner = '( crontab -l 2>/dev/null | grep -v run-ibdiagnet.sh ) | crontab -'
    r = subprocess.run(['sudo', '-n', '-u', 'lldpq', 'bash', '-c', inner],
                       capture_output=True, text=True, timeout=15)
    return r.returncode == 0, (r.stderr or r.stdout)

# hours == 0 -> turn the schedule OFF (remove the line)
if hours == 0:
    ok, err = install('')
    if not ok:
        print(json.dumps({'success': False, 'error': f'Failed to clear schedule: {err[:200]}'}))
        raise SystemExit
    print(json.dumps({'success': True, 'hours': 0, 'target': ''}))
    raise SystemExit

if not target_id:
    print(json.dumps({'success': False, 'error': 'No target selected'}))
    raise SystemExit

# Resolve target (same rules as the manual run action).
ufm_host = os.environ.get('UFM_SSH_HOST', '')
ufm_user = os.environ.get('UFM_SSH_USER', 'root')
host = user = bin_path = docker_ct = ''
if target_id == 'ufm':
    if not ufm_host:
        print(json.dumps({'success': False,
            'error': 'UFM SSH host not configured. Set up UFM SSH first, then schedule.'}))
        raise SystemExit
    host, user = ufm_host, ufm_user
    bin_path = os.environ.get('IBDIAGNET_BIN') or '/opt/ufm/opensm/bin/ibdiagnet'
    docker_ct = os.environ.get('IBDIAGNET_DOCKER') or 'ufm'
else:
    try:
        import yaml
        data = yaml.safe_load(open(lldpq_dir + '/devices.yaml')) or {}
        duser = (data.get('defaults', {}) or {}).get('username', 'admin')
        for ip, val in (data.get('devices', {}) or {}).items():
            hn, u = '', duser
            if isinstance(val, str):
                hn = (val.strip().split() or [''])[0]
            elif isinstance(val, dict):
                hn, u = val.get('hostname', ''), val.get('username', duser)
            if hn == target_id:
                host, user, bin_path = ip, u, 'ibdiagnet'
                break
    except Exception as e:
        print(json.dumps({'success': False, 'error': f'Cannot read devices.yaml: {e}'}))
        raise SystemExit
    if not host:
        print(json.dumps({'success': False, 'error': f'Unknown target: {target_id}'}))
        raise SystemExit

# cron schedule expression
if hours == 1:
    expr = '0 * * * *'
elif hours >= 24:
    expr = '0 0 * * *'
else:
    expr = f'0 */{hours} * * *'

env_parts = [f"IBDIAG_TARGET='{host}'", f"IBDIAG_USER='{user}'", f"IBDIAG_BIN='{bin_path}'"]
if docker_ct:
    env_parts.append(f"IBDIAG_DOCKER='{docker_ct}'")
runner = os.path.join(lldpq_dir, 'run-ibdiagnet.sh')
cron_line = f"{expr} {' '.join(env_parts)} {runner} >/dev/null 2>&1"

ok, err = install(cron_line)
if not ok:
    print(json.dumps({'success': False, 'error': f'Failed to install schedule: {err[:200]}'}))
    raise SystemExit
print(json.dumps({'success': True, 'hours': hours, 'target': target_id}))
PY
        ;;

    *)
        echo "{\"success\": false, \"error\": \"Unknown action: ${ACTION}\"}"
        ;;
esac
