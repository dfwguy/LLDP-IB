#!/usr/bin/env bash
# LLDPq-IB UFM API Proxy
#
# Optional UFM (Unified Fabric Manager) REST API integration.
# Requires UFM_URL and UFM_TOKEN environment variables (set in /etc/lldpq.conf).
# When UFM is not configured, returns {"configured": false}.
#
# Copyright (c) 2024-2026 LLDPq Project - Licensed under MIT License

set -uo pipefail

source /var/www/html/auth-guard.sh 2>/dev/null || true

ACTION="${QUERY_STRING#*action=}"
ACTION="${ACTION%%&*}"

case "$ACTION" in
    status|get-config) ;;   # readable by any logged-in user
    save-config)
        require_admin 2>/dev/null || true
        ;;
    *)
        if ! ${AUTH_REQUIRE_ADMIN:-false}; then
            require_admin 2>/dev/null || true
        fi
        ;;
esac

echo "Content-Type: application/json"
echo ""

source /etc/lldpq.conf 2>/dev/null || true
UFM_URL="${UFM_URL:-}"
UFM_TOKEN="${UFM_TOKEN:-}"

# Helper: emit JSON error
json_err() {
    printf '{"success": false, "error": %s}\n' "$(python3 -c "import json,sys;print(json.dumps(sys.argv[1]))" "$1")"
    exit 0
}

# Quick guard: most actions require UFM configured. Configuration actions must
# remain available on first boot, before UFM_URL exists in /etc/lldpq.conf.
if [ -z "$UFM_URL" ] && [ "$ACTION" != "status" ] && [ "$ACTION" != "get-config" ] && [ "$ACTION" != "save-config" ]; then
    json_err "UFM is not configured. Set UFM_URL and UFM_TOKEN environment variables."
fi

# Helper: GET request to UFM via curl
ufm_get() {
    local path="$1"
    local url="${UFM_URL%/}${path}"
    local headers=()
    if [ -n "$UFM_TOKEN" ]; then
        headers+=(-H "Authorization: Basic $UFM_TOKEN")
    fi
    # UFM commonly uses self-signed certs; skip verification (operator can disable
    # with UFM_VERIFY_TLS=true if needed).
    local insecure="--insecure"
    [ "${UFM_VERIFY_TLS:-false}" = "true" ] && insecure=""
    curl -s -S $insecure --max-time 30 "${headers[@]}" "$url" 2>&1
}

case "$ACTION" in
    # -------------------------------------------------------------------
    # status: ping UFM, return configuration state + version
    # Used by all UI pages to decide whether to show UFM-specific widgets.
    # -------------------------------------------------------------------
    status)
        if [ -z "$UFM_URL" ]; then
            echo '{"configured": false, "reason": "UFM_URL not set"}'
            exit 0
        fi
        VERSION_OUT=$(ufm_get "/ufmRest/app/ufm_version" 2>&1)
        if echo "$VERSION_OUT" | grep -q '"ufm_release_version"\|"version"'; then
            python3 -c "
import json, sys
try:
    v = json.loads(sys.argv[1])
    print(json.dumps({
        'configured': True,
        'reachable': True,
        'url': sys.argv[2],
        'version': v.get('ufm_release_version') or v.get('version') or 'unknown',
    }))
except Exception as e:
    print(json.dumps({'configured': True, 'reachable': False, 'url': sys.argv[2], 'error': str(e)}))
" "$VERSION_OUT" "$UFM_URL"
        else
            python3 -c "
import json, sys
print(json.dumps({
    'configured': True,
    'reachable': False,
    'url': sys.argv[2],
    'error': sys.argv[1][:200] or 'No response from UFM',
}))
" "$VERSION_OUT" "$UFM_URL"
        fi
        ;;

    # -------------------------------------------------------------------
    # alerts: fetch active alerts from UFM
    # -------------------------------------------------------------------
    alerts)
        # UFM 6.x: the events endpoint is /ufmRest/app/events. It does NOT accept
        # an 'active' query arg (that returns HTTP 400 plain text). Fetch the full
        # event list and normalize/sort here.
        RAW=$(ufm_get "/ufmRest/app/events")
        python3 -c "
import json, sys
raw_text = sys.argv[1]
try:
    raw = json.loads(raw_text)
except Exception as e:
    print(json.dumps({'success': False, 'error': f'Failed to parse UFM response: {e}', 'raw': raw_text[:200]}))
    sys.exit(0)

# UFM event schema: id, name, type, event_type, severity, timestamp, counter,
# category, object_name (the GUID/source).
items = raw if isinstance(raw, list) else raw.get('events') or raw.get('items') or []

def bucket(sev):
    s = (sev or '').lower()
    if 'crit' in s or 'error' in s or 'alert' in s or 'fatal' in s: return 'critical'
    if 'warn' in s or 'minor' in s or 'major' in s: return 'warning'
    return 'info'

counts = {'critical': 0, 'warning': 0, 'info': 0}
normalized = []
for e in items:
    if not isinstance(e, dict):
        continue
    b = bucket(e.get('severity'))
    counts[b] += 1
    normalized.append({
        'id': e.get('id') or e.get('event_id'),
        'severity': b,
        'severity_raw': e.get('severity') or '',
        'source': e.get('object_name') or e.get('source') or e.get('source_id') or '',
        'description': e.get('name') or e.get('description') or e.get('msg') or '',
        'timestamp': e.get('timestamp') or e.get('time') or '',
        'category': e.get('category') or e.get('type') or '',
    })

# Most recent first so the UI shows the latest events at the top.
normalized.sort(key=lambda x: x.get('timestamp') or '', reverse=True)

print(json.dumps({
    'success': True,
    'count': len(normalized),
    'summary': counts,
    'alerts': normalized[:200],   # cap to 200 for UI safety
}))
" "$RAW"
        ;;

    # -------------------------------------------------------------------
    # systems: fetch switch + HCA inventory from UFM
    # Used to cross-validate against ib_topology.json
    # -------------------------------------------------------------------
    systems)
        RAW=$(ufm_get "/ufmRest/resources/systems")
        python3 -c "
import json, sys
try:
    raw = json.loads(sys.argv[1])
except Exception as e:
    print(json.dumps({'success': False, 'error': f'Failed to parse UFM response: {e}'}))
    sys.exit(0)

items = raw if isinstance(raw, list) else raw.get('systems') or []
print(json.dumps({
    'success': True,
    'count': len(items),
    'systems': items[:500],
}))
" "$RAW"
        ;;

    # -------------------------------------------------------------------
    # links: fetch IB links from UFM (topology cross-check)
    # -------------------------------------------------------------------
    links)
        RAW=$(ufm_get "/ufmRest/resources/links")
        python3 -c "
import json, sys
try:
    raw = json.loads(sys.argv[1])
except Exception as e:
    print(json.dumps({'success': False, 'error': f'Failed to parse UFM response: {e}'}))
    sys.exit(0)

items = raw if isinstance(raw, list) else raw.get('links') or []
print(json.dumps({
    'success': True,
    'count': len(items),
    'links': items[:2000],
}))
" "$RAW"
        ;;

    # -------------------------------------------------------------------
    # ber-history: query UFM telemetry endpoint for BER over time
    # We expose a simple GET wrapper; the UI builds the Prometheus-style query.
    # -------------------------------------------------------------------
    ber-history)
        QUERY="${QUERY_STRING#*action=ber-history&}"
        # Pass arbitrary query params after action= straight to UFM
        # (e.g. action=ber-history&device_guid=0x...&duration=1h)
        RAW=$(ufm_get "/ufmRestV3/telemetry/historical/ports?${QUERY}")
        # IMPORTANT: validate the response. Many UFM 6.x deployments do not expose
        # a historical telemetry endpoint on the main REST gateway (returns 404
        # HTML), which would otherwise reach the browser as raw HTML and crash
        # JSON.parse ("Unexpected token '<'"). Always emit clean JSON.
        python3 -c "
import json, sys
raw_text = sys.argv[1]
try:
    data = json.loads(raw_text)
except Exception:
    print(json.dumps({
        'success': False,
        'available': False,
        'error': 'UFM historical telemetry is not available via REST on this UFM version. '
                 'BER and error counters are collected locally every ~5 minutes — see the Link Errors page.',
    }))
    sys.exit(0)
# Valid JSON from UFM: pass it through unchanged for the UI normalizer.
print(json.dumps(data))
" "$RAW"
        ;;

    # -------------------------------------------------------------------
    # validate-topology: compare UFM's view with our ib_topology.json
    # Returns: discrepancies between local discovery and UFM's authoritative view.
    # -------------------------------------------------------------------
    validate-topology)
        SYSTEMS_RAW=$(ufm_get "/ufmRest/resources/systems")
        LINKS_RAW=$(ufm_get "/ufmRest/resources/links")
        python3 -c "
import json, sys, os

try:
    ufm_systems_raw = json.loads(sys.argv[1])
    ufm_links_raw = json.loads(sys.argv[2])
except Exception as e:
    print(json.dumps({'success': False, 'error': f'UFM JSON parse: {e}'}))
    sys.exit(0)

ufm_systems = ufm_systems_raw if isinstance(ufm_systems_raw, list) else ufm_systems_raw.get('systems') or []
ufm_links = ufm_links_raw if isinstance(ufm_links_raw, list) else ufm_links_raw.get('links') or []

# Load local topology
try:
    with open('/var/www/html/monitor-results/ib_topology.json') as f:
        topo = json.load(f)
except Exception as e:
    print(json.dumps({'success': False, 'error': f'Local topology missing: {e}'}))
    sys.exit(0)

# GUIDs are written with a '0x' prefix locally but UFM returns them bare; strip
# the prefix and lowercase both sides so the comparison is apples-to-apples
# (otherwise every node looks like a discrepancy).
def norm_guid(g):
    g = (g or '').strip().lower()
    return g[2:] if g.startswith('0x') else g

# SHARP aggregation nodes appear as link endpoints in our topology but UFM lists
# them under /resources/modules, NOT /resources/systems -- so they would always
# look like a 'discrepancy'. They are expected; exclude them from the compare.
def is_aggregation(n):
    d = ((n.get('description') or '') + ' ' + (n.get('hostname') or '')).lower()
    return 'aggregation node' in d or (n.get('role') or '').lower() == 'aggregator'

local_guids = set()
aggregation_excluded = 0
for n in topo.get('nodes', []):
    g = norm_guid(n.get('guid'))
    if not g:
        continue
    if is_aggregation(n):
        aggregation_excluded += 1
        continue
    local_guids.add(g)
ufm_guids = set()
for s in ufm_systems:
    g = norm_guid(s.get('guid') or s.get('system_guid'))
    if g: ufm_guids.add(g)

only_local = sorted(local_guids - ufm_guids)
only_ufm = sorted(ufm_guids - local_guids)
common = local_guids & ufm_guids

print(json.dumps({
    'success': True,
    'local_node_count': len(local_guids),
    'ufm_node_count': len(ufm_guids),
    'common_count': len(common),
    'only_in_local': only_local[:50],
    'only_in_ufm': only_ufm[:50],
    'aggregation_excluded': aggregation_excluded,
    'ufm_link_count': len(ufm_links),
    'local_link_count': len(topo.get('links', [])),
}))
" "$SYSTEMS_RAW" "$LINKS_RAW"
        ;;

    # -------------------------------------------------------------------
    # get-config: return current UFM settings (token masked) for the form
    # -------------------------------------------------------------------
    get-config)
        python3 -c "
import json, os
def mask(t):
    if not t: return ''
    return t[:4] + '...' + t[-4:] if len(t) > 12 else '***'
print(json.dumps({
    'success': True,
    'configured': bool(os.environ.get('UFM_URL', '').strip()),
    'url':        os.environ.get('UFM_URL', ''),
    'token_set':  bool(os.environ.get('UFM_TOKEN', '').strip()),
    'token_mask': mask(os.environ.get('UFM_TOKEN', '')),
    'verify_tls': os.environ.get('UFM_VERIFY_TLS', 'false').lower() == 'true',
}))
" 2>/dev/null
        ;;

    # -------------------------------------------------------------------
    # save-config: write UFM_URL / UFM_TOKEN / UFM_VERIFY_TLS to lldpq.conf
    # Body: JSON {url, username, password, token, verify_tls}
    #   - If "token" is provided -> stored as-is.
    #   - Else username+password -> base64("user:pass") -> stored as token.
    #   - To clear: send {url:""} -- both URL and token wiped.
    # /etc/lldpq.conf is chmod 664 root:www-data, so the www-data CGI
    # process can write directly without sudo.
    # -------------------------------------------------------------------
    save-config)
        # Buffer POST body
        POST_DATA=""
        if [ "${REQUEST_METHOD:-}" = "POST" ] && [ -n "${CONTENT_LENGTH:-}" ] && [ "$CONTENT_LENGTH" -gt 0 ] 2>/dev/null; then
            POST_DATA=$(dd bs=4096 count=$(( (CONTENT_LENGTH + 4095) / 4096 )) 2>/dev/null | head -c "$CONTENT_LENGTH")
        fi
        export POST_DATA
        python3 << 'PY'
import json, os, sys, base64, fcntl, re

CONF = '/etc/lldpq.conf'
LOCK = CONF + '.lock'

def out(d):
    print(json.dumps(d))
    sys.exit(0)

try:
    data = json.loads(os.environ.get('POST_DATA') or '{}')
except Exception as e:
    out({'success': False, 'error': f'Invalid JSON: {e}'})

url        = (data.get('url') or '').strip()
token_in   = (data.get('token') or '').strip()
username   = (data.get('username') or '').strip()
password   = (data.get('password') or '').strip()
verify_tls = bool(data.get('verify_tls'))

# Validate URL only if user is configuring (not clearing)
if url:
    if not re.match(r'^https?://[^\s]+$', url):
        out({'success': False, 'error': 'URL must start with http:// or https:// and have no spaces'})

# Resolve token
if token_in:
    token = token_in
elif username and password:
    token = base64.b64encode(f'{username}:{password}'.encode()).decode()
else:
    # Allow URL-only updates (keep existing token) ONLY if we're not clearing
    token = None

# When user clears URL, also wipe token / verify_tls
if not url:
    token = ''

updates = {
    'UFM_URL':        url,
    'UFM_VERIFY_TLS': 'true' if verify_tls else 'false',
}
if token is not None:
    updates['UFM_TOKEN'] = token

# Read+modify+write /etc/lldpq.conf with an exclusive lock
try:
    lock_fd = open(LOCK, 'w')
    fcntl.flock(lock_fd, fcntl.LOCK_EX)
    try:
        try:
            with open(CONF) as f:
                lines = f.readlines()
        except FileNotFoundError:
            lines = []
        seen = set()
        new_lines = []
        for ln in lines:
            key = ln.split('=', 1)[0].strip() if '=' in ln else ''
            if key in updates:
                new_lines.append(f'{key}={updates[key]}\n')
                seen.add(key)
            else:
                new_lines.append(ln)
        for k, v in updates.items():
            if k not in seen:
                new_lines.append(f'{k}={v}\n')
        with open(CONF, 'w') as f:
            f.writelines(new_lines)
    finally:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        lock_fd.close()
except PermissionError as e:
    out({'success': False, 'error': f'Cannot write {CONF}: {e}. The CGI user (www-data) must be in the conf file group.'})
except Exception as e:
    out({'success': False, 'error': str(e)})

out({
    'success': True,
    'message': 'UFM settings saved. The change takes effect on the next API request.' if url else 'UFM settings cleared.',
    'url': url,
    'token_set': bool(token),
    'verify_tls': verify_tls,
})
PY
        ;;

    *)
        echo "{\"success\": false, \"error\": \"Unknown UFM action: ${ACTION}\"}"
        ;;
esac
