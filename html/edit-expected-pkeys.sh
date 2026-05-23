#!/usr/bin/env bash
# edit-expected-pkeys.sh - Read/Write expected_pkeys.yaml via CGI

source "$(dirname "$0")/auth-guard.sh"
require_admin

source /etc/lldpq.conf 2>/dev/null || true
LLDPQ_USER="${LLDPQ_USER:-lldpq}"
LLDPQ_DIR="${LLDPQ_DIR:-/home/lldpq/lldpq}"
POLICY_FILE="$LLDPQ_DIR/expected_pkeys.yaml"
METHOD="${REQUEST_METHOD:-GET}"

echo "Content-Type: application/json"
echo ""

json_escape() {
    python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))'
}

if [ "$METHOD" = "GET" ]; then
    if [ -f "$POLICY_FILE" ]; then
        CONTENT=$(json_escape < "$POLICY_FILE")
        echo "{\"success\": true, \"content\": $CONTENT, \"path\": \"$POLICY_FILE\"}"
    else
        DEFAULT='partitions:
  "0x7fff":
    name: "default (full membership)"
    required_on: all
    min_members: 1
'
        CONTENT=$(printf "%s" "$DEFAULT" | json_escape)
        echo "{\"success\": true, \"content\": $CONTENT, \"path\": \"$POLICY_FILE\", \"default\": true}"
    fi
    exit 0
fi

if [ "$METHOD" = "POST" ]; then
    if [ -n "$CONTENT_LENGTH" ] && [ "$CONTENT_LENGTH" -gt 0 ] 2>/dev/null; then
        POST_DATA=$(dd bs=1 count="$CONTENT_LENGTH" 2>/dev/null)
    else
        POST_DATA=$(cat)
    fi
    CONTENT=$(printf "%s" "$POST_DATA" | python3 -c '
import sys, json
try:
    print(json.load(sys.stdin).get("content", ""))
except Exception:
    print("")
' 2>/dev/null)
    if [ -z "$CONTENT" ]; then
        echo '{"success": false, "error": "No content provided"}'
        exit 0
    fi

    VALIDATION=$(printf "%s" "$CONTENT" | python3 -c '
import sys, yaml
try:
    data = yaml.safe_load(sys.stdin) or {}
    if "partitions" not in data:
        print("YAML Error: top-level partitions: key is required")
    else:
        print("valid")
except yaml.YAMLError as e:
    print(f"YAML Error: {str(e)[:160]}")
except Exception as e:
    print(f"Error: {str(e)[:160]}")
' 2>/dev/null)
    if [ "$VALIDATION" != "valid" ]; then
        printf '{"success": false, "error": %s}\n' "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$VALIDATION")"
        exit 0
    fi

    [ -f "$POLICY_FILE" ] && cp "$POLICY_FILE" "${POLICY_FILE}.bak" 2>/dev/null || true
    printf "%s\n" "$CONTENT" > "$POLICY_FILE"
    if [ $? -eq 0 ]; then
        chown "$LLDPQ_USER:www-data" "$POLICY_FILE" 2>/dev/null || true
        chmod 664 "$POLICY_FILE" 2>/dev/null || true
        echo '{"success": true, "message": "expected_pkeys.yaml saved. It will be applied on the next monitor cycle."}'
    else
        echo '{"success": false, "error": "Failed to write expected_pkeys.yaml"}'
    fi
    exit 0
fi

echo '{"success": false, "error": "Invalid method"}'
