#!/usr/bin/env bash
# setup-ufm-ssh.sh - Authorize the collector key on the UFM appliance host and
# wire "ibdiagnet via UFM docker".
#
# UFM Enterprise runs containerized; ibdiagnet lives INSIDE the `ufm` container
# (e.g. /opt/ufm/opensm/bin/ibdiagnet). To run a full fabric diagnostic, LLDPq
# SSHes to the UFM HOST and `docker exec <container> ibdiagnet ...`. This script:
#   1) installs lldpq's RSA public key into <user>@<host>:~/.ssh/authorized_keys
#      (standard Linux host -- NOT the MLNX-OS CLI flow that send-key.sh uses)
#   2) verifies key auth works AND ibdiagnet is runnable inside the container
#   3) persists UFM_SSH_HOST/USER + IBDIAGNET_DOCKER/BIN to /etc/lldpq.conf
#
# Run AS lldpq (the collector-key owner). Emits a single JSON line on stdout.
#
# Usage: setup-ufm-ssh.sh -h HOST -u USER -p PASSWORD [-c CONTAINER] [-b BIN]
#
# Copyright (c) 2024-2026 LLDPq Project - Licensed under MIT License

set -uo pipefail

HOST="" ; SUSER="root" ; PW="" ; CONTAINER="ufm" ; BIN="/opt/ufm/opensm/bin/ibdiagnet"
while getopts "h:u:p:c:b:" o; do
    case "$o" in
        h) HOST="$OPTARG" ;; u) SUSER="$OPTARG" ;; p) PW="$OPTARG" ;;
        c) CONTAINER="$OPTARG" ;; b) BIN="$OPTARG" ;;
    esac
done

err() { python3 -c 'import json,sys; print(json.dumps({"success": False, "error": sys.argv[1]}))' "$1"; exit 0; }

[ -n "$HOST" ] || err "UFM SSH host is required"
[ -n "$PW" ]   || err "UFM SSH password is required"
printf '%s' "$HOST" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$|^[0-9.]+$' || err "Invalid host"
printf '%s' "$SUSER" | grep -Eq '^[A-Za-z0-9._-]+$' || err "Invalid user"
printf '%s' "$CONTAINER" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$' || err "Invalid container name"
printf '%s' "$BIN" | grep -Eq '^[A-Za-z0-9 _./-]+$' || err "Invalid binary path"

KEY="$HOME/.ssh/id_rsa"
[ -f "${KEY}.pub" ] || ssh-keygen -t rsa -b 4096 -N '' -f "$KEY" >/dev/null 2>&1
PUB=$(cat "${KEY}.pub" 2>/dev/null)
[ -n "$PUB" ] || err "No collector public key (id_rsa.pub) available"

# 1) Install the key over a PASSWORD session (force password auth for this step).
INSTALL='mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && ( grep -qF "'"$PUB"'" ~/.ssh/authorized_keys || echo "'"$PUB"'" >> ~/.ssh/authorized_keys )'
if ! sshpass -p "$PW" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=12 -o PreferredAuthentications=password -o PubkeyAuthentication=no \
        "$SUSER@$HOST" "$INSTALL" >/dev/null 2>&1; then
    err "Could not SSH to $SUSER@$HOST with the given password (key install failed)"
fi

# 2) Verify key auth + ibdiagnet runnable inside the container.
VER=$(ssh -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=12 "$SUSER@$HOST" "docker exec $CONTAINER $BIN --version 2>&1 | head -1" 2>/dev/null)
if ! printf '%s' "$VER" | grep -qiE 'ibdiagnet|[0-9]+\.[0-9]+'; then
    python3 -c 'import json,sys; print(json.dumps({"success": False, "error": "Key installed, but ibdiagnet could not run inside the container. Check the container name and binary path.", "detail": sys.argv[1][:200]}))' "$VER"
    exit 0
fi

# 3) Persist config to /etc/lldpq.conf (lldpq is in the www-data group; the file
#    is group-writable). One-time setup -- no locking needed.
python3 - "$HOST" "$SUSER" "$CONTAINER" "$BIN" <<'PY'
import sys
host, suser, container, binp = sys.argv[1:5]
CONF = '/etc/lldpq.conf'
updates = {'UFM_SSH_HOST': host, 'UFM_SSH_USER': suser,
           'IBDIAGNET_DOCKER': container, 'IBDIAGNET_BIN': binp}
try:
    lines = open(CONF).read().splitlines()
except FileNotFoundError:
    lines = []
seen = set(); out = []
for ln in lines:
    k = ln.split('=', 1)[0].strip() if '=' in ln else ''
    if k in updates:
        out.append(f'{k}={updates[k]}'); seen.add(k)
    else:
        out.append(ln)
for k, v in updates.items():
    if k not in seen:
        out.append(f'{k}={v}')
open(CONF, 'w').write('\n'.join(out) + '\n')
PY

python3 -c 'import json,sys; print(json.dumps({"success": True, "host": sys.argv[1], "user": sys.argv[2], "container": sys.argv[3], "bin": sys.argv[4], "ibdiagnet_version": sys.argv[5][:80]}))' \
    "$HOST" "$SUSER" "$CONTAINER" "$BIN" "$VER"
