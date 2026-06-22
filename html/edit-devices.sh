#!/usr/bin/env bash
# edit-devices.sh - Read/Write devices.yaml via CGI
# Called by nginx fcgiwrap

source "$(dirname "$0")/auth-guard.sh"
require_admin

# Load config with fallback
source /etc/lldpq.conf 2>/dev/null || true
LLDPQ_USER="${LLDPQ_USER:-$(whoami)}"
LLDPQ_HOME="${LLDPQ_DIR:-$HOME/lldpq}"

# devices.yaml location
DEVICES_FILE="$LLDPQ_HOME/devices.yaml"

# Read request method
METHOD="${REQUEST_METHOD:-GET}"

# Output headers
echo "Content-Type: application/json"
echo ""

if [ "$METHOD" = "GET" ]; then
    # Read and return devices.yaml content
    if [ -f "$DEVICES_FILE" ]; then
        # Escape content for JSON
        CONTENT=$(cat "$DEVICES_FILE" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')
        echo "{\"success\": true, \"content\": $CONTENT}"
    else
        echo "{\"success\": false, \"error\": \"File not found: $DEVICES_FILE\"}"
    fi
    
elif [ "$METHOD" = "POST" ]; then
    # Read POST data from stdin
    if [ -n "$CONTENT_LENGTH" ] && [ "$CONTENT_LENGTH" -gt 0 ] 2>/dev/null; then
        POST_DATA=$(dd bs=1 count="$CONTENT_LENGTH" 2>/dev/null)
    else
        POST_DATA=$(cat)
    fi

    # Validate-only mode (live lint in the editor): check YAML WITHOUT saving and
    # return the offending line number so the UI can flag it as you type.
    MODE=$(echo "$POST_DATA" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("mode",""))
except: print("")' 2>/dev/null)
    if [ "$MODE" = "validate" ]; then
        printf '%s' "$POST_DATA" | python3 -c '
import sys, json
try:
    content = json.loads(sys.stdin.read()).get("content", "")
except Exception:
    print(json.dumps({"success": True, "valid": False, "error": "bad request"})); sys.exit(0)
try:
    import yaml
    yaml.safe_load(content)
    print(json.dumps({"success": True, "valid": True}))
except yaml.YAMLError as e:
    mark = getattr(e, "problem_mark", None)
    line = (mark.line + 1) if mark is not None else None
    msg = getattr(e, "problem", None) or str(e).splitlines()[0]
    print(json.dumps({"success": True, "valid": False, "line": line, "error": str(msg)[:160]}))
except Exception as e:
    print(json.dumps({"success": True, "valid": False, "error": str(e)[:160]}))
'
        exit 0
    fi

    # Extract content from JSON using Python
    CONTENT=$(echo "$POST_DATA" | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get("content", ""))
except:
    print("")
' 2>/dev/null)
    
    if [ -n "$CONTENT" ]; then
        # Validate YAML syntax before saving
        VALIDATION=$(echo "$CONTENT" | python3 -c '
import sys, yaml
try:
    yaml.safe_load(sys.stdin)
    print("valid")
except yaml.YAMLError as e:
    print(f"YAML Error: {str(e)[:100]}")
except Exception as e:
    print(f"Error: {str(e)[:100]}")
' 2>/dev/null)
        
        if [ "$VALIDATION" = "valid" ]; then
            # Create backup before writing
            if [ -f "$DEVICES_FILE" ]; then
                cp "$DEVICES_FILE" "${DEVICES_FILE}.bak" 2>/dev/null
            fi
            
            # Write new content
            echo "$CONTENT" > "$DEVICES_FILE"
            
            if [ $? -eq 0 ]; then
                sudo -n chown "${LLDPQ_USER:-$(whoami)}:www-data" "$DEVICES_FILE" 2>/dev/null || true
                sudo -n chmod 664 "$DEVICES_FILE" 2>/dev/null || true
                echo "{\"success\": true, \"message\": \"devices.yaml saved successfully\"}"
            else
                echo "{\"success\": false, \"error\": \"Failed to write file\"}"
            fi
        else
            echo "{\"success\": false, \"error\": \"$VALIDATION\"}"
        fi
    else
        echo "{\"success\": false, \"error\": \"No content provided\"}"
    fi
else
    echo "{\"success\": false, \"error\": \"Invalid method\"}"
fi
