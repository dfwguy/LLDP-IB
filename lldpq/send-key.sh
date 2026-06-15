#!/usr/bin/env bash
# send-key.sh - SSH Key Distribution for MLNX-OS Switches
#
# Distributes the LLDPq-IB collector's SSH public key to all MLNX-OS switches
# defined in devices.yaml using the MLNX-OS CLI command:
#     ssh client user admin authorized-key sshv2 "<pubkey>"
#
# Copyright (c) 2024-2026 LLDPq Project - Licensed under MIT License
#
# USAGE:
#   ./send-key.sh                       # Interactive mode (prompts for password)
#   ./send-key.sh -p "password"         # Non-interactive
#   ./send-key.sh -k ~/.ssh/id_rsa.pub  # Custom key path

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
eval "$(python3 "$SCRIPT_DIR/parse_devices.py")"

DEFAULT_SSH_KEY=""
for key in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub"; do
    if [ -f "$key" ]; then
        DEFAULT_SSH_KEY="$key"
        break
    fi
done

SSH_KEY=""
PASSWORD=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -p|--password) PASSWORD="$2"; shift 2 ;;
        -k|--key)      SSH_KEY="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [-p password] [-k ssh_key_path]"
            echo ""
            echo "Distributes the LLDPq-IB SSH public key to all MLNX-OS switches in devices.yaml."
            echo ""
            echo "  -p, --password    SSH password for initial authentication (admin / Nvidia01! by default)"
            echo "  -k, --key         Path to SSH public key (default: ~/.ssh/id_ed25519.pub or id_rsa.pub)"
            echo "  -h, --help        Show this help"
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# Resolve key path
if [ -z "$SSH_KEY" ]; then
    SSH_KEY="$DEFAULT_SSH_KEY"
fi
if [ -z "$SSH_KEY" ] || [ ! -f "$SSH_KEY" ]; then
    echo "ERROR: SSH public key not found. Generate one with: ssh-keygen -t ed25519"
    exit 1
fi

# Password: -p flag, then SSH_PASSWORD env, then interactive prompt.
if [ -z "$PASSWORD" ]; then
    PASSWORD="${SSH_PASSWORD:-}"
fi
if [ -z "$PASSWORD" ]; then
    read -rsp "MLNX-OS admin password: " PASSWORD
    echo
fi

# Require sshpass (MLNX-OS doesn't support ssh-copy-id directly)
if ! command -v sshpass >/dev/null 2>&1; then
    echo "ERROR: sshpass is required. Install: apt install sshpass"
    exit 1
fi

PUB_KEY="$(cat "$SSH_KEY")"
PRIV_KEY="${SSH_KEY%.pub}"
TOTAL=0
SUCCESS=0
FAILED=0
FAILED_DEVICES=()

push_key() {
    local device=$1
    local user=$2
    local hostname=$3

    # MLNX-OS command to authorize the key (quoted, single line).
    local cmd="ssh client user ${user} authorized-key sshv2 \"${PUB_KEY}\""

    # MLNX-OS admin is CLI-only: feed enable-mode config over an interactive PTY
    # (stdin), NOT as an `ssh host "cmd"` exec (which the switch rejects with
    # "UNIX shell commands cannot be executed using this account").
    printf 'enable\nconfigure terminal\n%s\nwrite memory\nexit\nexit\n' "$cmd" \
        | timeout 30 sshpass -p "$PASSWORD" ssh -tt \
            -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o PubkeyAuthentication=no \
            -o PreferredAuthentications=keyboard-interactive,password \
            -o ConnectTimeout=10 -o LogLevel=ERROR \
            "${user}@${device}" >/dev/null 2>&1

    # Verify key-based auth now works (the push exit code alone is not reliable).
    if printf 'exit\n' | timeout 15 ssh -i "$PRIV_KEY" -tt \
            -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=10 -o LogLevel=ERROR \
            "${user}@${device}" >/dev/null 2>&1; then
        echo "  [OK]   ${hostname} (${device})"
        SUCCESS=$((SUCCESS+1))
    else
        echo "  [FAIL] ${hostname} (${device})"
        FAILED=$((FAILED+1))
        FAILED_DEVICES+=("${hostname}")
    fi
}

echo ""
echo "Distributing SSH key to ${#devices[@]} MLNX-OS switches..."
echo "Key: $SSH_KEY"
echo ""

for device in "${!devices[@]}"; do
    IFS=' ' read -r user hostname <<< "${devices[$device]}"
    TOTAL=$((TOTAL+1))
    push_key "$device" "$user" "$hostname"
done

echo ""
echo "==================================================="
echo "Results: ${SUCCESS}/${TOTAL} succeeded, ${FAILED} failed"
if [ "$FAILED" -gt 0 ]; then
    echo "Failed devices: ${FAILED_DEVICES[*]}"
fi
echo "==================================================="

exit 0
