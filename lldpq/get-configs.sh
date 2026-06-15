#!/usr/bin/env bash
# LLDPq-IB Configuration Backup
# Fetches running config from each MLNX-OS switch and stores it under
# $WEB_ROOT/configs/ for the Configs page to display.
#
# Copyright (c) 2024-2026 LLDPq Project - Licensed under MIT License

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
eval "$(python3 "$SCRIPT_DIR/parse_devices.py")"

source /etc/lldpq.conf 2>/dev/null || true
WEB_ROOT="${WEB_ROOT:-/var/www/html}"
MAX_PARALLEL="${GET_CONFIGS_MAX_PARALLEL:-50}"
case "$MAX_PARALLEL" in
    ''|*[!0-9]*|0) MAX_PARALLEL=50 ;;
esac

MOCK_MODE="${LLDPQ_IB_MOCK:-0}"

DATE=$(date +%F--%H-%M)
TMP_BASE="${TMPDIR:-/tmp}/lldpq-ib-configs-${DATE}"
mkdir -p "$TMP_BASE"
sudo mkdir -p "$WEB_ROOT/configs"

unreachable_hosts_file=$(mktemp)
trap 'rm -f "$unreachable_hosts_file"' EXIT

SSH_OPTS="-o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=10 -o LogLevel=ERROR"

# Pull running config from one MLNX-OS switch.
# MLNX-OS has two useful outputs:
#   * 'show running-config'  -- CLI commands form, human readable
#   * 'show running-config full' -- full dump including defaults
fetch_config() {
    local device=$1
    local user=$2
    local hostname=$3
    
    if [ "$MOCK_MODE" = "1" ]; then
        local mock="$SCRIPT_DIR/../tests/fixtures/mlnx-os/${hostname}.txt"
        if [ -f "$mock" ]; then
            # Mock mode: use IB_IDENTITY section as a stand-in config
            sed -n '/===IB_IDENTITY_START===/,/===IB_IDENTITY_END===/p' "$mock" \
                | grep -v '===IB_IDENTITY' > "$TMP_BASE/${hostname}.txt"
            return 0
        fi
        echo "$device $hostname" >> "$unreachable_hosts_file"
        return 1
    fi
    
    if ! ping -c 1 -W 1 "$device" > /dev/null 2>&1; then
        echo "$device $hostname" >> "$unreachable_hosts_file"
        return 1
    fi

    # MLNX-OS admin is CLI-only: drive an interactive enable-mode session over a
    # PTY (stdin) rather than `ssh host "show running-config"` (exec is rejected).
    # Strip the login banner + prompt/echo lines so the saved file is clean config.
    if printf 'enable\nno cli session paging enable\nshow running-config\nexit\nexit\n' \
            | timeout 40 ssh -tt $SSH_OPTS "${user}@${device}" 2>/dev/null \
            | tr -d '\r' \
            | sed -e '/\[standalone:/d' -e '/\[master\]/d' \
                  -e '/^NVIDIA Switch$/d' -e '/^NVIDIA MLNX-OS/d' \
                  -e '/^Last login/d' -e '/^Last failed login/d' \
                  -e '/^There w/d' -e '/^Number of total/d' -e '/^Connection to /d' \
                  -e '/^enable$/d' -e '/^no cli session paging enable$/d' \
                  -e '/^show running-config$/d' -e '/^exit$/d' \
            > "$TMP_BASE/${hostname}.txt" && [ -s "$TMP_BASE/${hostname}.txt" ]; then
        echo "Config pulled: $hostname"
    else
        rm -f "$TMP_BASE/${hostname}.txt"
        echo "$device $hostname" >> "$unreachable_hosts_file"
    fi
}

wait_for_slot() {
    while (( $(jobs -rp | wc -l) >= MAX_PARALLEL )); do
        wait -n 2>/dev/null || true
    done
}

echo "Pulling configs from ${#devices[@]} devices (max parallel: $MAX_PARALLEL, mock: $MOCK_MODE)..."
for device in "${!devices[@]}"; do
    IFS=' ' read -r user hostname <<< "${devices[$device]}"
    wait_for_slot
    fetch_config "$device" "$user" "$hostname" &
done
wait

# Publish to web root (replace previous batch)
sudo rm -rf "$WEB_ROOT/configs/"*
if compgen -G "$TMP_BASE/*.txt" > /dev/null; then
    sudo cp "$TMP_BASE/"*.txt "$WEB_ROOT/configs/"
    sudo chown -R "${LLDPQ_USER:-$(whoami)}:www-data" "$WEB_ROOT/configs/"
    sudo find "$WEB_ROOT/configs/" -type d -exec chmod 775 {} \;
    sudo find "$WEB_ROOT/configs/" -type f -exec chmod 664 {} \;
fi

UNREACH=$(wc -l < "$unreachable_hosts_file" 2>/dev/null | xargs)
echo "Configs pulled: $(ls "$TMP_BASE" 2>/dev/null | wc -l | xargs), unreachable: ${UNREACH:-0}"

rm -rf "$TMP_BASE"

exit 0
