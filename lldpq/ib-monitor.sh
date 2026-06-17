#!/usr/bin/env bash
# IB Monitor - LLDPq InfiniBand Edition
# Single SSH session per MLNX-OS switch + Parallel limits + Parallel analysis
#
# Copyright (c) 2024-2026 LLDPq Project
# Licensed under MIT License - see LICENSE file for details

START_TIME=$(date +%s)
echo "Starting IB monitoring at $(date)"

DATE=$(date '+%Y-%m-%d %H-%M-%S')
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Load device list and config
eval "$(python3 "$SCRIPT_DIR/parse_devices.py")"
source /etc/lldpq.conf 2>/dev/null || true
WEB_ROOT="${WEB_ROOT:-/var/www/html}"

# ── Data-source guard (LEGACY SSH/shell collector) ──────────────────────────
# This collector sends a marker-based SHELL script over `ssh host "<script>"`
# (exec) and uses `ib <util>` ibutils. That model only works on shell-capable
# switches. CLI-only MLNX-OS admin accounts reject exec ("UNIX shell commands
# cannot be executed") and have no `ib*` utilities (the `ib` keyword is an
# ibdiagnet wrapper). For those fabrics, fabric data comes from ufm-adapter.py
# (UFM REST) and switch hardware from ib-hw-collect.sh. Refuse to run in
# ufm/hybrid mode so this cannot overwrite UFM-sourced JSON with empties.
DATA_SOURCE="${LLDPQ_DATA_SOURCE:-auto}"
if [ "$DATA_SOURCE" = "auto" ] && [ -n "${UFM_URL:-}" ]; then DATA_SOURCE="hybrid"; fi
if [ "$DATA_SOURCE" = "ufm" ] || [ "$DATA_SOURCE" = "hybrid" ]; then
    echo "ib-monitor.sh: skipped (LLDPQ_DATA_SOURCE=$DATA_SOURCE). Fabric data is" \
         "collected by ufm-adapter.py (UFM REST) + ib-hw-collect.sh (switch HW)."
    exit 0
fi

# === TUNING PARAMETERS ===
MAX_PARALLEL="${MONITOR_MAX_PARALLEL:-${MAX_PARALLEL:-100}}"
case "$MAX_PARALLEL" in
    ''|*[!0-9]*|0) MAX_PARALLEL=100 ;;
esac
SSH_TIMEOUT=60   # SSH connection timeout
COMMAND_TIMEOUT=180  # Total per-device command budget

# Mock mode: if LLDPQ_IB_MOCK=1, read from tests/fixtures/mlnx-os/<hostname>.txt instead of SSH
MOCK_MODE="${LLDPQ_IB_MOCK:-0}"
MOCK_DIR="${LLDPQ_IB_MOCK_DIR:-$SCRIPT_DIR/../tests/fixtures/mlnx-os}"

mkdir -p "$SCRIPT_DIR/monitor-results"
for d in ib-identity ib-interfaces ib-link-diag ib-counters ib-transceiver \
         ib-topology ib-linkinfo ib-sm ib-perfquery ib-pkey ib-multicast \
         ib-qos ib-sharp ib-hardware optical-data transceiver-data hardware-data log-data; do
    mkdir -p "$SCRIPT_DIR/monitor-results/$d"
done

unreachable_hosts_file=$(mktemp)
active_jobs_file=$(mktemp)
trap 'rm -f "$unreachable_hosts_file" "$active_jobs_file"' EXIT

# SSH options with multiplexing
SSH_OPTS="-o StrictHostKeyChecking=no -o ControlMaster=auto -o ControlPath=~/.ssh/cm-%r@%h:%p -o ControlPersist=60 -o BatchMode=yes -o ConnectTimeout=$SSH_TIMEOUT"

PING="ping"

ping_test() {
    local device=$1
    local hostname=$2
    $PING -c 1 -W 0.5 "$device" > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo "$device $hostname" >> "$unreachable_hosts_file"
        return 1
    fi
    return 0
}

# ============================================================================
# Single SSH session collects ALL IB data from one MLNX-OS switch
# ============================================================================
# MLNX-OS notes:
#   - Default shell on login is CLI (Cisco-like). Native CLI commands use 'show ...'
#   - ibutils (ibnetdiscover, iblinkinfo, sminfo, perfquery, saquery) are available
#     directly as 'ib <command>' from the CLI. No sudo, no shell escape required.
#   - All output goes to stdout; we use marker sections to slice it server-side.
# ============================================================================
execute_commands_optimized() {
    local device=$1
    local user=$2
    local hostname=$3
    local outfile="monitor-results/${hostname}_raw_data.txt"
    
    # MOCK mode: copy fixture instead of SSH
    if [ "$MOCK_MODE" = "1" ]; then
        local mock_file="$MOCK_DIR/${hostname}.txt"
        if [ -f "$mock_file" ]; then
            cp "$mock_file" "$outfile"
            return 0
        else
            echo "$device $hostname (mock fixture not found: $mock_file)" >> "$unreachable_hosts_file"
            return 1
        fi
    fi
    
    timeout $COMMAND_TIMEOUT ssh $SSH_OPTS -q "$user@$device" '
        HOSTNAME_VAR="'"$hostname"'"
        
        # =====================================================================
        # SECTION 1: Identity (hostname, version, SN, model)
        # =====================================================================
        echo "===IB_IDENTITY_START==="
        show version 2>/dev/null
        echo "---SEP---"
        show inventory 2>/dev/null
        echo "===IB_IDENTITY_END==="
        
        # =====================================================================
        # SECTION 2: Interface status (port list, speed, state)
        # =====================================================================
        echo "===IB_INTERFACES_START==="
        show interfaces ib status 2>/dev/null
        echo "===IB_INTERFACES_END==="
        
        # =====================================================================
        # SECTION 3: Link diagnostics (per-port code + status)
        # =====================================================================
        echo "===IB_LINK_DIAG_START==="
        show interfaces ib link-diagnostics 2>/dev/null
        echo "===IB_LINK_DIAG_END==="
        
        # =====================================================================
        # SECTION 4: Interface counters (errors, symbol errors, VL15 drops)
        # =====================================================================
        echo "===IB_COUNTERS_START==="
        show interfaces ib 2>/dev/null
        echo "===IB_COUNTERS_END==="
        
        # =====================================================================
        # SECTION 5: Transceiver inventory (vendor PN, SN, rev per port)
        # =====================================================================
        echo "===IB_TRANSCEIVER_START==="
        show interfaces ib transceiver 2>/dev/null
        echo "===IB_TRANSCEIVER_END==="
        
        # =====================================================================
        # SECTION 6: Cable optical diagnostics (RX/TX power, temperature)
        # =====================================================================
        echo "===IB_CABLE_DIAG_START==="
        show interfaces ib transceiver diagnostics 2>/dev/null
        echo "===IB_CABLE_DIAG_END==="
        
        # =====================================================================
        # SECTION 7: Topology (ibnetdiscover) - GUIDs, LIDs, neighbors
        # =====================================================================
        echo "===IB_TOPOLOGY_START==="
        ib ibnetdiscover -p 2>/dev/null
        echo "===IB_TOPOLOGY_END==="
        
        # =====================================================================
        # SECTION 8: Link info (iblinkinfo) - per-link state + speed
        # =====================================================================
        echo "===IB_LINKINFO_START==="
        ib iblinkinfo --line 2>/dev/null
        echo "===IB_LINKINFO_END==="
        
        # =====================================================================
        # SECTION 9: Subnet Manager status (sminfo)
        # =====================================================================
        echo "===IB_SM_START==="
        ib sminfo 2>/dev/null
        echo "===IB_SM_END==="
        
        # =====================================================================
        # SECTION 10: Performance counters (perfquery)
        # Note: perfquery without args dumps local port; we use ibqueryerrors
        # which is faster across the fabric. Falls back to perfquery -a.
        # =====================================================================
        echo "===IB_PERFQUERY_START==="
        echo "IBUTILS_NOT_AVAILABLE_ON_MLNX_OS_CLI"
        echo "===IB_PERFQUERY_END==="
        
        # =====================================================================
        # SECTION 11: P_Key partitions
        # =====================================================================
        echo "===IB_PKEY_START==="
        show ib partition 2>/dev/null
        echo "===IB_PKEY_END==="
        
        # =====================================================================
        # SECTION 12: Multicast groups (saquery -m)
        # =====================================================================
        echo "===IB_MULTICAST_START==="
        echo "MULTICAST_NOT_AVAILABLE_VIA_SWITCH_CLI"
        echo "===IB_MULTICAST_END==="
        
        # =====================================================================
        # SECTION 13: QoS profiles (Service Level / VL mapping)
        # =====================================================================
        echo "===IB_QOS_START==="
        echo "QOS_NOT_AVAILABLE_VIA_SWITCH_CLI"
        echo "===IB_QOS_END==="
        
        # =====================================================================
        # SECTION 14: SHARP aggregation nodes (auto-detected; empty if disabled)
        # =====================================================================
        echo "===IB_SHARP_START==="
        echo "SHARP_NOT_AVAILABLE_VIA_SWITCH_CLI"
        echo "===IB_SHARP_END==="
        
        # =====================================================================
        # SECTION 15: Hardware sensors (power, fan, temperature)
        # =====================================================================
        echo "===IB_HARDWARE_START==="
        echo "--- POWER ---"
        show power 2>/dev/null
        echo "--- FAN ---"
        show fan 2>/dev/null
        echo "--- TEMPERATURE ---"
        show temperature 2>/dev/null
        echo "===IB_HARDWARE_END==="
        
        # =====================================================================
        # SECTION 16: System logs (recent errors/warnings)
        # =====================================================================
        echo "===IB_LOG_START==="
        show log files 2>/dev/null | head -20
        echo "---SEP---"
        show log continuous 2>/dev/null | grep -E "ERR|WARN|FAIL|DOWN" | tail -50
        echo "===IB_LOG_END==="
    ' > "$outfile" 2>/dev/null
    
    local ssh_status=$?
    if [ $ssh_status -ne 0 ] || [ ! -s "$outfile" ]; then
        echo "$device $hostname" >> "$unreachable_hosts_file"
        return 1
    fi
    return 0
}

# ============================================================================
# Parse raw output into per-section files
# ============================================================================
parse_raw_output() {
    local hostname=$1
    local raw="monitor-results/${hostname}_raw_data.txt"
    [ ! -f "$raw" ] && return
    
    # Extract each marker section into its own file
    extract_section() {
        local marker=$1
        local outfile=$2
        sed -n "/===${marker}_START===/,/===${marker}_END===/p" "$raw" | \
            grep -v "===${marker}_" > "$outfile"
    }
    
    extract_section "IB_IDENTITY"     "monitor-results/ib-identity/${hostname}.txt"
    extract_section "IB_INTERFACES"   "monitor-results/ib-interfaces/${hostname}.txt"
    extract_section "IB_LINK_DIAG"    "monitor-results/ib-link-diag/${hostname}.txt"
    extract_section "IB_COUNTERS"     "monitor-results/ib-counters/${hostname}.txt"
    extract_section "IB_TRANSCEIVER"  "monitor-results/ib-transceiver/${hostname}.txt"
    extract_section "IB_CABLE_DIAG"   "monitor-results/optical-data/${hostname}_optical.txt"
    extract_section "IB_TOPOLOGY"     "monitor-results/ib-topology/${hostname}.txt"
    extract_section "IB_LINKINFO"     "monitor-results/ib-linkinfo/${hostname}.txt"
    extract_section "IB_SM"           "monitor-results/ib-sm/${hostname}.txt"
    extract_section "IB_PERFQUERY"    "monitor-results/ib-perfquery/${hostname}.txt"
    extract_section "IB_PKEY"         "monitor-results/ib-pkey/${hostname}.txt"
    extract_section "IB_MULTICAST"    "monitor-results/ib-multicast/${hostname}.txt"
    extract_section "IB_QOS"          "monitor-results/ib-qos/${hostname}.txt"
    extract_section "IB_SHARP"        "monitor-results/ib-sharp/${hostname}.txt"
    extract_section "IB_HARDWARE"     "monitor-results/hardware-data/${hostname}_hardware.txt"
    extract_section "IB_LOG"          "monitor-results/log-data/${hostname}_logs.txt"
    
    # Clean up raw file (per-section files are the source of truth)
    rm -f "$raw"
}

# ============================================================================
# Process a single device (ping -> SSH -> parse)
# ============================================================================
process_device() {
    local device=$1
    local user=$2
    local hostname=$3
    
    # In mock mode skip ping
    if [ "$MOCK_MODE" != "1" ]; then
        ping_test "$device" "$hostname" || return 1
    fi
    
    execute_commands_optimized "$device" "$user" "$hostname"
    if [ $? -eq 0 ]; then
        parse_raw_output "$hostname"
    fi
}

# ============================================================================
# Main loop: parallel SSH per device
# ============================================================================
cd "$SCRIPT_DIR"
echo "Collecting from ${#devices[@]} devices (max parallel: $MAX_PARALLEL, mock: $MOCK_MODE)..."

for device in "${!devices[@]}"; do
    IFS=' ' read -r user hostname <<< "${devices[$device]}"
    
    while [ "$(jobs -p | wc -l)" -ge "$MAX_PARALLEL" ]; do
        sleep 0.1
    done
    
    process_device "$device" "$user" "$hostname" &
done
wait

COLLECT_END=$(date +%s)
COLLECT_DURATION=$((COLLECT_END - START_TIME))
echo "Collection complete in ${COLLECT_DURATION}s"

# ============================================================================
# PARALLEL ANALYSIS PHASE - run all process_ib_*.py scripts
# ============================================================================
echo "Analyzing..."
ANALYZE_START=$(date +%s)

python3 process_ib_topology.py    >/dev/null 2>&1 &
python3 process_ib_links.py       >/dev/null 2>&1 &
python3 process_ib_sm.py          >/dev/null 2>&1 &
python3 process_ib_transceiver.py >/dev/null 2>&1 &
python3 process_ib_pkey.py        >/dev/null 2>&1 &
python3 process_ib_multicast.py   >/dev/null 2>&1 &
python3 process_ib_qos.py         >/dev/null 2>&1 &
python3 process_ib_sharp.py       >/dev/null 2>&1 &
python3 process_hardware_data.py  >/dev/null 2>&1 &
python3 process_log_data.py       >/dev/null 2>&1 &

wait

ANALYZE_END=$(date +%s)
ANALYZE_DURATION=$((ANALYZE_END - ANALYZE_START))
echo "Analysis complete in ${ANALYZE_DURATION}s"

# Aggregate high-level fabric health after individual parsers finish.
if [ -f "$SCRIPT_DIR/process_fabric_health.py" ]; then
    python3 "$SCRIPT_DIR/process_fabric_health.py" >/dev/null 2>&1 || true
fi

# Generate the cytoscape-friendly topology.js (must run AFTER parsers, since
# it consumes monitor-results/ib_topology.json + ib_link_errors.json).
WEB_ROOT_FOR_TOPO="${WEB_ROOT:-/var/www/html}"
if [ -f "$SCRIPT_DIR/generate_ib_topology.py" ]; then
    python3 "$SCRIPT_DIR/generate_ib_topology.py" \
        --lldpq-dir "$SCRIPT_DIR" \
        --web-root  "$WEB_ROOT_FOR_TOPO" >/dev/null 2>&1 || true
fi

# ============================================================================
# Archive snapshot -- write a point-in-time JSON to monitor-results/snapshots/
# so the Discovery Archive page can rewind state. Keeps the most recent 50.
# ============================================================================
SNAPSHOTS_DIR="$SCRIPT_DIR/monitor-results/snapshots"
mkdir -p "$SNAPSHOTS_DIR"
SNAPSHOT_TS=$(date '+%Y%m%d-%H%M%S')
SNAPSHOT_FILE="$SNAPSHOTS_DIR/lldpq-ib-${SNAPSHOT_TS}.json"
python3 - "$SCRIPT_DIR/monitor-results" "$SNAPSHOT_FILE" <<'PYSNAP' 2>/dev/null || true
import json, os, sys, datetime
mr, out = sys.argv[1], sys.argv[2]
def load(name):
    p = os.path.join(mr, name)
    if not os.path.exists(p):
        return None
    try:
        with open(p) as f:
            return json.load(f)
    except Exception:
        return None
snap = {
    "generated_at":    datetime.datetime.now(datetime.timezone.utc)
                          .strftime("%Y-%m-%dT%H:%M:%SZ"),
    "ib_topology":     load("ib_topology.json"),
    "ib_sm_status":    load("ib_sm_status.json"),
    "ib_sm_history":   load("ib_sm_history.json"),
    "ib_link_errors":  load("ib_link_errors.json"),
    "fabric_health":   load("fabric_health.json"),
    "ib_pkey":         load("ib_pkey.json"),
    "transceiver_inventory": load("transceiver_inventory.json"),
    "log_summary":     load("log_summary.json"),
}
with open(out, "w") as f:
    json.dump(snap, f, separators=(",", ":"))
PYSNAP
# Rotate: keep most recent 50 snapshots
if command -v ls >/dev/null 2>&1; then
    ls -1t "$SNAPSHOTS_DIR"/lldpq-ib-*.json 2>/dev/null | tail -n +51 | xargs -r rm -f
fi

# ============================================================================
# Publish results to web root
# ============================================================================
if [ -n "$WEB_ROOT" ] && [ -d "$WEB_ROOT" ]; then
    cp -r monitor-results/* "$WEB_ROOT/monitor-results/" 2>/dev/null || \
        sudo cp -r monitor-results/* "$WEB_ROOT/monitor-results/" 2>/dev/null || true
    chown -R "${USER:-lldpq}:www-data" "$WEB_ROOT/monitor-results" 2>/dev/null || true
fi

# ============================================================================
# Summary
# ============================================================================
TOTAL=$((${COLLECT_DURATION} + ${ANALYZE_DURATION}))
UNREACHABLE_COUNT=$(wc -l < "$unreachable_hosts_file" 2>/dev/null || echo 0)
echo "IB monitor finished: ${#devices[@]} devices, ${UNREACHABLE_COUNT} unreachable, ${TOTAL}s total"
