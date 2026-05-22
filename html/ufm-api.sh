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

# Quick guard: most actions require UFM configured
if [ -z "$UFM_URL" ] && [ "$ACTION" != "status" ]; then
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
        RAW=$(ufm_get "/ufmRest/app/events?active=true")
        python3 -c "
import json, sys
try:
    raw = json.loads(sys.argv[1])
except Exception as e:
    print(json.dumps({'success': False, 'error': f'Failed to parse UFM response: {e}'}))
    sys.exit(0)

# UFM event schema (typical fields)
# id, severity, source, description, timestamp, category, type
items = raw if isinstance(raw, list) else raw.get('events') or raw.get('items') or []
counts = {'critical': 0, 'warning': 0, 'info': 0}
normalized = []
for e in items:
    sev = (e.get('severity') or '').lower()
    if sev in counts: counts[sev] += 1
    normalized.append({
        'id': e.get('id') or e.get('event_id'),
        'severity': sev or 'info',
        'source': e.get('source') or e.get('source_id') or '',
        'description': e.get('description') or e.get('msg') or '',
        'timestamp': e.get('timestamp') or e.get('time') or '',
        'category': e.get('category') or e.get('type') or '',
    })

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
        echo "$RAW"
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

local_guids = set((n.get('guid') or '').lower() for n in topo.get('nodes', []))
ufm_guids = set()
for s in ufm_systems:
    g = (s.get('guid') or s.get('system_guid') or '').lower()
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
