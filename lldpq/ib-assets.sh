#!/usr/bin/env bash
# LLDPq-IB Assets Script
# Parallel quick check of all IB switches: reachability + identity (MLNX-OS)
# Outputs assets.ini for the web UI Assets page.
#
# Copyright (c) 2024-2026 LLDPq Project - Licensed under MIT License
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
eval "$(python3 "$SCRIPT_DIR/parse_devices.py")"

source /etc/lldpq.conf 2>/dev/null || true
WEB_ROOT="${WEB_ROOT:-/var/www/html}"
ASSETS_MAX_PARALLEL="${ASSETS_MAX_PARALLEL:-50}"
case "$ASSETS_MAX_PARALLEL" in
  ''|*[!0-9]*|0) ASSETS_MAX_PARALLEL=50 ;;
esac

MOCK_MODE="${LLDPQ_IB_MOCK:-0}"

TMPFILE="$SCRIPT_DIR/assets.tmp"
UNREACH="$SCRIPT_DIR/unreachable.tmp"
FINAL="$SCRIPT_DIR/assets.ini"
CACHE_FILE="$WEB_ROOT/device-cache.json"

rm -f "$TMPFILE" "$UNREACH"

SSH_OPTS="-o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=10 -o LogLevel=ERROR"

# Single-device probe: ping + MLNX-OS identity query
probe_device() {
    local device=$1
    local user=$2
    local hostname=$3
    
    if [ "$MOCK_MODE" != "1" ]; then
        if ! ping -c 1 -W 1 "$device" > /dev/null 2>&1; then
            echo "$device $hostname" >> "$UNREACH"
            return
        fi
    fi
    
    # Query MLNX-OS for identity fields via 'show version' and 'show inventory'.
    # Output parsed inline; defaults to "unknown" on failure.
    local out
    if [ "$MOCK_MODE" = "1" ]; then
        local mock="$SCRIPT_DIR/../tests/fixtures/mlnx-os/${hostname}.txt"
        if [ -f "$mock" ]; then
            out=$(sed -n '/===IB_IDENTITY_START===/,/===IB_IDENTITY_END===/p' "$mock")
        else
            out=""
        fi
    else
        # MLNX-OS admin is CLI-only: interactive enable-mode over a PTY, not exec.
        out=$(printf 'enable\nno cli session paging enable\nshow version\nshow inventory\nexit\nexit\n' \
            | timeout 20 ssh -tt $SSH_OPTS "$user@$device" 2>/dev/null | tr -d '\r')
    fi
    
    if [ -z "$out" ]; then
        echo "$device $hostname" >> "$UNREACH"
        return
    fi
    
    # Parse fields from output. MLNX-OS output examples:
    #   Product name      : MLNX-OS
    #   Product release   : 3.11.2400
    #   Build ID          : ...
    #   Build date        : ...
    #   Target arch       : ...
    #   Host ID           : ...
    #   System serial num : MT2342X12345
    #   System UUID       : ...
    #   Uptime            : 5d 12h ...
    
    local release product_name serial uptime model
    release=$(echo "$out" | grep -m1 -iE '^[[:space:]]*Product release' | awk -F':' '{print $2}' | xargs)
    product_name=$(echo "$out" | grep -m1 -iE '^[[:space:]]*Product name' | awk -F':' '{print $2}' | xargs)
    serial=$(echo "$out" | grep -m1 -iE '^[[:space:]]*System serial num' | awk -F':' '{print $2}' | xargs)
    uptime=$(echo "$out" | grep -m1 -iE '^[[:space:]]*Uptime' | awk -F':' '{print $2}' | xargs)
    # CHASSIS row is space-separated ("CHASSIS  MQM9700-NS2F  <serial> ..."); take col 2.
    model=$(echo "$out" | awk '/^[[:space:]]*CHASSIS[[:space:]]/{print $2; exit}')
    [ -z "$model" ] && model=$(echo "$out" | grep -m1 -iE '^[[:space:]]*Product model' | awk -F':' '{print $2}' | xargs)
    
    # Defaults
    release="${release:-unknown}"
    product_name="${product_name:-MLNX-OS}"
    serial="${serial:-unknown}"
    uptime="${uptime:-unknown}"
    model="${model:-unknown}"
    
    # Write to TMPFILE (one line per device, tab-separated for parser robustness)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$hostname" "$device" "$model" "$serial" "$release" "$product_name" "$uptime" \
        >> "$TMPFILE"
}

# Main loop -- parallel up to ASSETS_MAX_PARALLEL
echo "Probing ${#devices[@]} devices (max parallel: $ASSETS_MAX_PARALLEL, mock: $MOCK_MODE)..."

for device in "${!devices[@]}"; do
    IFS=' ' read -r user hostname <<< "${devices[$device]}"
    while [ "$(jobs -p | wc -l)" -ge "$ASSETS_MAX_PARALLEL" ]; do
        sleep 0.1
    done
    probe_device "$device" "$user" "$hostname" &
done
wait

# Build final assets.ini with header
{
    echo "# LLDPq-IB Assets - $(date '+%Y-%m-%d %H:%M:%S')"
    echo "# DEVICE-NAME	IP	MODEL	SERIAL	RELEASE	OS	UPTIME"
    if [ -f "$TMPFILE" ]; then
        sort "$TMPFILE"
    fi
} > "$FINAL"

REACHED=$(wc -l < "$TMPFILE" 2>/dev/null | xargs || echo 0)
UNREACHED=$(wc -l < "$UNREACH" 2>/dev/null | xargs || echo 0)
echo "Assets: $REACHED reached, $UNREACHED unreachable, total ${#devices[@]}"

# Publish to web root
if [ -n "$WEB_ROOT" ] && [ -d "$WEB_ROOT" ]; then
    cp "$FINAL" "$WEB_ROOT/assets.ini" 2>/dev/null || \
        sudo cp "$FINAL" "$WEB_ROOT/assets.ini" 2>/dev/null || true
    chown "${USER:-lldpq}:www-data" "$WEB_ROOT/assets.ini" 2>/dev/null || true
    chmod 664 "$WEB_ROOT/assets.ini" 2>/dev/null || true
fi

rm -f "$TMPFILE" "$UNREACH"
