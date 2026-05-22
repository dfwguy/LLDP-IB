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
    status) ;;   # always available -- used to detect UFM presence
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

    *)
        echo "{\"success\": false, \"error\": \"Unknown UFM action: ${ACTION}\"}"
        ;;
esac
