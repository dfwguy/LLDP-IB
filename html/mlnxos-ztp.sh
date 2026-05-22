#!/bin/bash
# MLNX-OS Zero Touch Provisioning script template
# Served by LLDPq-IB's DHCP server (option 239 cumulus-provision-url) to new MLNX-OS switches.
# Edit from the Provision page or via the Fabric Editor.
#
# NOTE: MLNX-OS ZTP uses the same provisioning URL hook as Cumulus (option 239 /
# default-url 114). On first boot, the switch downloads and executes this script.

set -e

# === Operator-edit fields (substituted by Provision page) ===
IMAGE_SERVER="__IMAGE_SERVER_IP__"
TARGET_OS_VERSION="__TARGET_OS_VERSION__"
DEFAULT_PASSWORD="__DEFAULT_PASSWORD__"
SSH_PUBLIC_KEY="__SSH_PUBLIC_KEY__"

# === Step 1: Wait until LLDPq-IB host is reachable ===
ping_until_reachable() {
    local target=$1
    local tries=0
    local max_tries=30
    while ! ping -c2 "$target" >/dev/null 2>&1; do
        tries=$((tries+1))
        if [ "$tries" -ge "$max_tries" ]; then
            echo "ERROR: cannot reach $target after $max_tries attempts"
            exit 1
        fi
        sleep 2
    done
}

ping_until_reachable "$IMAGE_SERVER"

# === Step 2: Resolve hostname from chassis serial via mapping file ===
# Reads /serial-mapping.txt from LLDPq-IB host: lines of "SERIAL HOSTNAME"
get_serial() {
    # MLNX-OS exposes serial via 'show inventory' parsed for the chassis row.
    # In a real ZTP environment this is also in the EEPROM at ONIE level.
    show inventory 2>/dev/null | awk '/CHASSIS/ {print $3; exit}'
}

resolve_hostname() {
    local serial="$1"
    local url="http://$IMAGE_SERVER/serial-mapping.txt"
    local mapping
    mapping=$(curl -sf "$url" 2>/dev/null || true)
    if [ -n "$mapping" ]; then
        echo "$mapping" | grep -v '^#' | grep -i "$serial" | awk '{print $2}' | head -1
    fi
}

MY_SERIAL=$(get_serial)
MY_HOSTNAME=$(resolve_hostname "$MY_SERIAL")
echo "Serial: ${MY_SERIAL:-unknown}  Resolved hostname: ${MY_HOSTNAME:-(none)}"

# === Step 3: Apply baseline config ===
# MLNX-OS configuration here is in CLI form. We pipe commands into 'cli' which
# is the MLNX-OS shell interpreter.
{
    echo "enable"
    echo "configure terminal"

    # Change admin password
    if [ -n "$DEFAULT_PASSWORD" ]; then
        echo "username admin password $DEFAULT_PASSWORD"
    fi

    # Install SSH key for LLDPq-IB collector
    if [ -n "$SSH_PUBLIC_KEY" ]; then
        echo "ssh client user admin authorized-key sshv2 \"$SSH_PUBLIC_KEY\""
    fi

    # Set hostname if resolved
    if [ -n "$MY_HOSTNAME" ]; then
        echo "hostname $MY_HOSTNAME"
    fi

    # Optionally apply a per-switch config from the LLDPq-IB host
    if [ -n "$MY_HOSTNAME" ]; then
        CONFIG_URL="http://$IMAGE_SERVER/generated_config_folder/${MY_HOSTNAME}.cfg"
        if curl -sf --head "$CONFIG_URL" 2>/dev/null | head -1 | grep -q "200"; then
            curl -sf "$CONFIG_URL" -o /tmp/lldpq-ib-startup.cfg
            echo "configuration file fetch http://$IMAGE_SERVER/generated_config_folder/${MY_HOSTNAME}.cfg"
            echo "configuration file install /tmp/lldpq-ib-startup.cfg"
        fi
    fi

    echo "write memory"
    echo "exit"
    echo "exit"
} | cli

echo "MLNX-OS ZTP complete for ${MY_HOSTNAME:-this device}"
exit 0
