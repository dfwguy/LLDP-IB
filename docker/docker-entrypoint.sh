#!/bin/bash
# LLDPq-IB Docker Entrypoint
# Self-healing startup: ensures all required files/dirs exist with correct permissions
# Starts: nginx + fcgiwrap + cron

set -e

echo "================================================"
echo "      LLDPq InfiniBand Edition"
echo "      Docker Container v$(cat /var/www/html/VERSION 2>/dev/null || echo '?')"
echo "================================================"

# ─── SSH Key Setup ───
# Support mounting host SSH keys as read-only volume
if [ -d /home/lldpq/.ssh-mount ]; then
    # Copy mounted keys (read-only mount → writable .ssh)
    cp -n /home/lldpq/.ssh-mount/id_* /home/lldpq/.ssh/ 2>/dev/null || true
    cp -n /home/lldpq/.ssh-mount/known_hosts /home/lldpq/.ssh/ 2>/dev/null || true
    chown -R lldpq:lldpq /home/lldpq/.ssh/
    chmod 700 /home/lldpq/.ssh
    chmod 600 /home/lldpq/.ssh/id_* 2>/dev/null || true
fi

if [ -f /home/lldpq/.ssh/id_rsa ] || [ -f /home/lldpq/.ssh/id_ed25519 ]; then
    echo "✓ SSH keys found"
else
    echo "⚠ No SSH keys — use SSH Setup from web UI, or mount keys:"
    echo "  docker run ... -v ~/.ssh:/home/lldpq/.ssh-mount:ro ..."
fi

# ─── UFM (optional) ───
if [ -n "$UFM_URL" ]; then
    sed -i "s|^UFM_URL=.*|UFM_URL=$UFM_URL|" /etc/lldpq.conf
    echo "  ✓ UFM URL: $UFM_URL"
fi
if [ -n "$UFM_TOKEN" ]; then
    sed -i "s|^UFM_TOKEN=.*|UFM_TOKEN=$UFM_TOKEN|" /etc/lldpq.conf
    echo "  ✓ UFM token configured"
fi
if [ -n "${UFM_VERIFY_TLS:-}" ]; then
    sed -i "s|^UFM_VERIFY_TLS=.*|UFM_VERIFY_TLS=$UFM_VERIFY_TLS|" /etc/lldpq.conf
fi

# ─── Fabric Diagnostic (ibdiagnet) config (optional) ───
# Persist to /etc/lldpq.conf so the CGI (diag-api.sh) and runner can `source` it.
# UFM_SSH_HOST/UFM_SSH_USER let the Diagnostics page run ibdiagnet on the UFM
# appliance; IBDIAGNET_* tune the scheduled run + parse-then-discard retention.
for kv in "UFM_USERNAME=${UFM_USERNAME:-}" "UFM_PASSWORD=${UFM_PASSWORD:-}" \
          "UFM_SSH_HOST=${UFM_SSH_HOST:-}" "UFM_SSH_USER=${UFM_SSH_USER:-root}" \
          "IBDIAGNET_TARGET=${IBDIAGNET_TARGET:-}" "IBDIAGNET_USER=${IBDIAGNET_USER:-admin}" \
          "IBDIAGNET_BIN=${IBDIAGNET_BIN:-ibdiagnet}" \
          "IBDIAGNET_KEEP_RAW=${IBDIAGNET_KEEP_RAW:-1}" "IBDIAGNET_KEEP_RUNS=${IBDIAGNET_KEEP_RUNS:-20}" \
          "IBDIAGNET_FLAGS=${IBDIAGNET_FLAGS:-}"; do
    key="${kv%%=*}"; val="${kv#*=}"
    if grep -q "^${key}=" /etc/lldpq.conf 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${val}|" /etc/lldpq.conf
    else
        echo "${kv}" >> /etc/lldpq.conf
    fi
done
[ -n "${UFM_SSH_HOST:-}" ] && echo "  ✓ UFM SSH host for ibdiagnet: ${UFM_SSH_HOST}"

# ─── Shared config permissions ───
usermod -aG lldpq www-data 2>/dev/null || true
usermod -aG www-data lldpq 2>/dev/null || true
touch /etc/lldpq.conf.lock
chown root:www-data /etc/lldpq.conf /etc/lldpq.conf.lock
chmod 664 /etc/lldpq.conf /etc/lldpq.conf.lock

# ─── devices.yaml Setup ───
if [ -f /home/lldpq/lldpq/devices.yaml ]; then
    chown lldpq:www-data /home/lldpq/lldpq/devices.yaml
    chmod 664 /home/lldpq/lldpq/devices.yaml
    echo "✓ devices.yaml loaded ($(grep -c '^\s*[0-9]' /home/lldpq/lldpq/devices.yaml 2>/dev/null || echo 0) devices)"
else
    echo "⚠ No devices.yaml found"
    echo "  Mount with: -v /path/to/devices.yaml:/home/lldpq/lldpq/devices.yaml"
fi

# ─── Topology files Setup ───
# Real files in web root (editable from web UI), symlinks in lldpq dir (used by scripts)
for f in topology.dot topology_config.yaml; do
    # If file exists in web root (baked in or volume-mounted), ensure symlink
    if [ -f "/var/www/html/$f" ] && [ ! -L "/home/lldpq/lldpq/$f" ]; then
        rm -f "/home/lldpq/lldpq/$f"
        ln -sf "/var/www/html/$f" "/home/lldpq/lldpq/$f"
    fi
    # If file only exists in lldpq dir (not a symlink), move to web root
    if [ -f "/home/lldpq/lldpq/$f" ] && [ ! -L "/home/lldpq/lldpq/$f" ] && [ ! -f "/var/www/html/$f" ]; then
        mv "/home/lldpq/lldpq/$f" "/var/www/html/$f"
        ln -sf "/var/www/html/$f" "/home/lldpq/lldpq/$f"
    fi
    if [ -f "/var/www/html/$f" ]; then
        chown lldpq:www-data "/var/www/html/$f"
        chmod 664 "/var/www/html/$f"
    fi
done
echo "✓ Topology files ready"

# ─── Persistent data directories ───
for dir in /home/lldpq/lldpq/monitor-results \
           /home/lldpq/lldpq/monitor-results/fabric-tables \
           /var/www/html/hstr \
           /var/www/html/configs \
           /var/www/html/monitor-results \
           /var/www/html/topology; do
    mkdir -p "$dir"
    chown -R lldpq:www-data "$dir"
    chmod 775 "$dir"
done

# Symlink monitor-results to web root
ln -sf /home/lldpq/lldpq/monitor-results /var/www/html/monitor-results 2>/dev/null || true

# ─── Cache files (assets.sh, provision, AI need these writable by lldpq) ───
for f in /var/www/html/device-cache.json /var/www/html/discovery-cache.json /var/www/html/inventory.json /var/www/html/ai-analysis.json; do
    [ ! -f "$f" ] && echo '{}' > "$f"
    chown lldpq:www-data "$f"
    chmod 664 "$f"
done

# ─── Generated configs dir + serial mapping (ZTP config resolution) ───
mkdir -p /var/www/html/generated_config_folder
chown lldpq:www-data /var/www/html/generated_config_folder
chmod 775 /var/www/html/generated_config_folder
if [ ! -f /var/www/html/serial-mapping.txt ]; then
    printf '# Serial → Hostname mapping for ZTP config resolution\n# Format: SERIAL_NUMBER  HOSTNAME\n\n' > /var/www/html/serial-mapping.txt
fi
chown lldpq:www-data /var/www/html/serial-mapping.txt
chmod 664 /var/www/html/serial-mapping.txt

# ─── Auth Setup (self-healing: recreate if missing) ───
if [ ! -f /etc/lldpq-users.conf ]; then
    echo "  Creating default users file..."
    ADMIN_HASH=$(echo -n "admin" | openssl dgst -sha256 | awk '{print $2}')
    OPERATOR_HASH=$(echo -n "operator" | openssl dgst -sha256 | awk '{print $2}')
    echo "admin:$ADMIN_HASH:admin" > /etc/lldpq-users.conf
    echo "operator:$OPERATOR_HASH:operator" >> /etc/lldpq-users.conf
    echo "  ⚠ Default credentials: admin/admin, operator/operator"
fi
chmod 600 /etc/lldpq-users.conf
chown www-data:www-data /etc/lldpq-users.conf
mkdir -p /var/lib/lldpq/sessions
mkdir -p /var/lib/lldpq/upgrade-jobs
chown -R www-data:www-data /var/lib/lldpq
chown lldpq:www-data /var/lib/lldpq/upgrade-jobs
chmod 700 /var/lib/lldpq/sessions
chmod 775 /var/lib/lldpq/upgrade-jobs
echo "✓ Authentication ready"

# ─── nginx listen port (LLDPQ_PORT, default 80) ───
# Lets the operator run the container on a non-default port while still using
# --network host (where Docker's -p mapping does not apply). When unset the
# config is left as-is (listen 80).
LLDPQ_PORT="${LLDPQ_PORT:-80}"
if [ "$LLDPQ_PORT" != "80" ]; then
    if [ -f /etc/nginx/sites-available/lldpq ]; then
        sed -i "s/^[[:space:]]*listen[[:space:]]\+80[[:space:]]\+default_server;/    listen ${LLDPQ_PORT} default_server;/" \
            /etc/nginx/sites-available/lldpq
        echo "  ✓ nginx listening on port ${LLDPQ_PORT} (LLDPQ_PORT override)"
    fi
fi

# ─── Demo mode (LLDPQ_DEMO=true) ───
# When set, copies the baked /opt/lldpq-demo baseline into the runtime
# locations so the UI shows a populated 4-spine + 8-leaf + 16-HCA fabric
# without needing real switches. Cron is disabled in demo mode so the
# fake JSON does not get overwritten by a failing ib-monitor pass.
if [ "${LLDPQ_DEMO:-false}" = "true" ] && [ -d /opt/lldpq-demo ]; then
    echo "================================================"
    echo "  LLDPQ_DEMO=true detected"
    echo "  Loading 4-spine + 8-leaf + 16-HCA fake fabric"
    echo "================================================"

    # JSON outputs (overwrite -- this is the whole point of demo mode)
    mkdir -p /home/lldpq/lldpq/monitor-results
    cp -r /opt/lldpq-demo/monitor-results/. /home/lldpq/lldpq/monitor-results/
    cp -r /opt/lldpq-demo/monitor-results/. /var/www/html/monitor-results/ 2>/dev/null || true

    # devices.yaml (only if user did not mount their own)
    if [ ! -f /home/lldpq/lldpq/devices.yaml ] \
            || grep -q '^# Example layout' /home/lldpq/lldpq/devices.yaml 2>/dev/null; then
        cp /opt/lldpq-demo/devices.yaml /home/lldpq/lldpq/devices.yaml
    fi

    # Web-root artefacts (+ pre-baked topology.js for the cytoscape view)
    cp /opt/lldpq-demo/assets.ini /var/www/html/assets.ini
    cp /opt/lldpq-demo/topology.dot /var/www/html/topology.dot
    cp /opt/lldpq-demo/topology_config.yaml /var/www/html/topology_config.yaml
    mkdir -p /var/www/html/topology
    cp /opt/lldpq-demo/topology/topology.js /var/www/html/topology/topology.js 2>/dev/null || true

    chown -R lldpq:www-data /home/lldpq/lldpq/monitor-results \
        /var/www/html/monitor-results \
        /var/www/html/assets.ini \
        /var/www/html/topology.dot \
        /var/www/html/topology_config.yaml \
        /home/lldpq/lldpq/devices.yaml 2>/dev/null || true
    chmod 664 /var/www/html/assets.ini /var/www/html/topology.dot \
        /var/www/html/topology_config.yaml \
        /home/lldpq/lldpq/devices.yaml 2>/dev/null || true

    echo "  ✓ Demo dataset loaded"
fi

# ─── Cron Setup ───
# lldpq         = ib-assets.sh + ib-monitor.sh + check_alerts.py (full IB pass)
# lldpq-trigger = web UI Refresh buttons (ib-assets/ib-monitor/get-configs on demand)
# get-conf      = MLNX-OS running-config backup
#
# In LLDPQ_DEMO=true mode cron is skipped so the baked fake fabric stays put.
# Data source: 'ssh' (per-switch SSH collection, ib-monitor) or 'ufm'/'hybrid'
# (UFM REST adapter for fabric data + optional switch-local hardware via SSH).
# 'auto' (default) picks hybrid when UFM_URL is configured, else ssh. NDR fabrics
# with CLI-only MLNX-OS switches must use hybrid -- ib-monitor's shell-style
# collection does not work against CLI-only admin accounts.
DATA_SOURCE="${LLDPQ_DATA_SOURCE:-auto}"
if [ "$DATA_SOURCE" = "auto" ]; then
    if [ -n "${UFM_URL:-}" ]; then DATA_SOURCE="hybrid"; else DATA_SOURCE="ssh"; fi
fi

if [ "${LLDPQ_DEMO:-false}" = "true" ]; then
    rm -f /etc/cron.d/lldpq
    echo "  ✓ Cron disabled (demo mode -- fake data is static)"
elif [ "$DATA_SOURCE" = "ufm" ] || [ "$DATA_SOURCE" = "hybrid" ]; then
    # UFM-backed: ufm-adapter pulls topology/SM/links/pkeys/assets from UFM REST.
    HW_LINE="# (switch hardware collection disabled: pure UFM mode)"
    if [ "$DATA_SOURCE" = "hybrid" ]; then
        # ib-hw-collect.sh collects switch hardware, renders the Hardware Analysis
        # page (from its results dir, where assets.ini lives) AND mirrors it to the
        # web root itself -- no extra generate/copy step needed.
        HW_LINE="*/15 * * * * lldpq cd /home/lldpq/lldpq && bash ib-hw-collect.sh > /dev/null 2>&1"
    fi
    cat > /etc/cron.d/lldpq << CRON
# LLDPq-IB ${DATA_SOURCE} mode -- fabric data from UFM REST
*/10 * * * * lldpq cd /home/lldpq/lldpq && python3 ufm-adapter.py >/dev/null 2>&1 ; python3 generate_ib_topology.py >/dev/null 2>&1 ; sudo /home/lldpq/lldpq/ib-local-scan.sh >/dev/null 2>&1
${HW_LINE}
* * * * * lldpq /usr/local/bin/lldpq-trigger > /dev/null 2>&1
0 */6 * * * lldpq cd /home/lldpq/lldpq && bash get-configs.sh > /dev/null 2>&1
CRON
    chmod 644 /etc/cron.d/lldpq
    echo "  ✓ Cron: ${DATA_SOURCE} mode (UFM adapter every 10m$([ "$DATA_SOURCE" = "hybrid" ] && echo ' + switch HW every 15m'))"
else
    cat > /etc/cron.d/lldpq << 'CRON'
# LLDPq-IB full run (ib-assets + ib-monitor + alerts) - every 10 minutes
*/10 * * * * lldpq /usr/local/bin/lldpq > /dev/null 2>&1
# Web trigger daemon (handles Refresh buttons from UI) - every minute
* * * * * lldpq /usr/local/bin/lldpq-trigger > /dev/null 2>&1
# Config backup - every 12 hours
0 */12 * * * lldpq /usr/local/bin/get-conf > /dev/null 2>&1
CRON
    chmod 644 /etc/cron.d/lldpq
fi

# ─── Optional scheduled Fabric Diagnostic (ibdiagnet) ───
# OFF by default. The 2-3 GB ibdiagnet run is heavy, so we only schedule it when
# the admin explicitly opts in with IBDIAGNET_SCHEDULE *and* IBDIAGNET_TARGET.
# The runner parses then discards the raw output (retention = IBDIAGNET_KEEP_RAW),
# so the data volume stays bounded. Never enabled in demo mode.
#   IBDIAGNET_SCHEDULE: a cron expression ("0 */2 * * *") or a bare integer N
#                       (interpreted as "every N hours").
rm -f /etc/cron.d/lldpq-ibdiagnet
if [ "${LLDPQ_DEMO:-false}" != "true" ] && [ -n "${IBDIAGNET_SCHEDULE:-}" ]; then
    if [ -z "${IBDIAGNET_TARGET:-}" ]; then
        echo "  ⚠ IBDIAGNET_SCHEDULE set but IBDIAGNET_TARGET empty — scheduled diagnostic NOT enabled"
    else
        SCHED="$IBDIAGNET_SCHEDULE"
        case "$SCHED" in
            ''|*[!0-9]*) : ;;                 # contains non-digits -> treat as a cron expression
            *) SCHED="0 */${SCHED} * * *" ;;  # bare integer -> every N hours
        esac
        DEFAULT_FLAGS="${IBDIAGNET_FLAGS:---get_phy_info --get_cable_info --extended_speeds all --sc}"
        {
            echo "# LLDPq-IB scheduled fabric diagnostic (opt-in via IBDIAGNET_SCHEDULE)"
            echo "${SCHED} lldpq IBDIAG_TARGET='${IBDIAGNET_TARGET}' IBDIAG_USER='${IBDIAGNET_USER:-admin}' IBDIAG_BIN='${IBDIAGNET_BIN:-ibdiagnet}' IBDIAG_FLAGS='${DEFAULT_FLAGS}' /home/lldpq/lldpq/run-ibdiagnet.sh > /dev/null 2>&1"
        } > /etc/cron.d/lldpq-ibdiagnet
        chmod 644 /etc/cron.d/lldpq-ibdiagnet
        echo "  ✓ Scheduled fabric diagnostic: '${SCHED}' on ${IBDIAGNET_TARGET} (parse-then-discard, keep_raw=${IBDIAGNET_KEEP_RAW:-1})"
    fi
fi

# ─── DHCP Server Setup ───
# Ensure DHCP directories and files exist
mkdir -p /var/lib/dhcp /etc/dhcp
touch /var/lib/dhcp/dhcpd.leases
[ ! -f /etc/dhcp/dhcpd.hosts ] && touch /etc/dhcp/dhcpd.hosts
chown lldpq:www-data /etc/dhcp/dhcpd.hosts
chmod 664 /etc/dhcp/dhcpd.hosts

# Default post-provision settings in lldpq.conf (if not present)
for key_val in "AUTO_BASE_CONFIG=false" "AUTO_ZTP_DISABLE=true" "AUTO_SET_HOSTNAME=true"; do
    key="${key_val%%=*}"
    grep -q "^${key}=" /etc/lldpq.conf 2>/dev/null || echo "$key_val" >> /etc/lldpq.conf
done
if ! grep -q '^LLDPQ_DEMO=' /etc/lldpq.conf 2>/dev/null; then
    echo "LLDPQ_DEMO=${LLDPQ_DEMO:-false}" >> /etc/lldpq.conf
else
    sed -i "s|^LLDPQ_DEMO=.*|LLDPQ_DEMO=${LLDPQ_DEMO:-false}|" /etc/lldpq.conf
fi

# Default dhcpd.conf if not configured yet (Ubuntu sample is useless)
if ! grep -q 'cumulus-provision-url\|LLDPq' /etc/dhcp/dhcpd.conf 2>/dev/null; then
    # Detect our IP for default config
    OUR_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    OUR_IP="${OUR_IP:-127.0.0.1}"
    # Detect subnet from our IP (replace last octet with 0)
    OUR_SUBNET=$(echo "$OUR_IP" | sed 's/\.[0-9]*$/.0/')
    OUR_GW=$(echo "$OUR_IP" | sed 's/\.[0-9]*$/.1/')
    
    cat > /etc/dhcp/dhcpd.conf << DHCPEOF
# /etc/dhcp/dhcpd.conf - Generated by LLDPq

ddns-update-style none;
authoritative;
log-facility local7;

option www-server code 72 = ip-address;
option default-url code 114 = text;
option cumulus-provision-url code 239 = text;
option space onie code width 1 length width 1;
option onie.installer_url code 1 = text;
option onie.updater_url   code 2 = text;
option onie.machine       code 3 = text;
option onie.arch          code 4 = text;
option onie.machine_rev   code 5 = text;

option space vivso code width 4 length width 1;
option vivso.onie code 42623 = encapsulate onie;
option vivso.iana code 0 = string;
option op125 code 125 = encapsulate vivso;

class "onie-vendor-classes" {
  match if substring(option vendor-class-identifier, 0, 11) = "onie_vendor";
  option vivso.iana 01:01:01;
}

# OOB Management subnet
shared-network OOB {
  subnet ${OUR_SUBNET} netmask 255.255.255.0 {
    range ${OUR_SUBNET%.*}.210 ${OUR_SUBNET%.*}.249;
    option routers ${OUR_GW};
    option domain-name "example.com";
    option domain-name-servers ${OUR_GW};
    option www-server ${OUR_IP};
    option default-url "http://${OUR_IP}/";
    option cumulus-provision-url "http://${OUR_IP}/mlnxos-ztp.sh";
    default-lease-time 172800;
    max-lease-time     345600;
  }
}

include "/etc/dhcp/dhcpd.hosts";
DHCPEOF
    chown lldpq:www-data /etc/dhcp/dhcpd.conf
    chmod 664 /etc/dhcp/dhcpd.conf
    echo "✓ Default DHCP config created (subnet: ${OUR_SUBNET}/24, server: ${OUR_IP})"
fi

# Write interface config if missing
if ! grep -q '^INTERFACES=' /etc/default/isc-dhcp-server 2>/dev/null; then
    echo 'INTERFACES="eth0"' > /etc/default/isc-dhcp-server
fi

# ZTP script in web root (writable by lldpq)
if [ ! -f /var/www/html/mlnxos-ztp.sh ]; then
    echo '#!/bin/bash' > /var/www/html/mlnxos-ztp.sh
    echo '# MLNX-OS Zero Touch Provisioning' >> /var/www/html/mlnxos-ztp.sh
    echo '# Edit this script from the Provision page' >> /var/www/html/mlnxos-ztp.sh
fi
chown lldpq:www-data /var/www/html/mlnxos-ztp.sh
chmod 775 /var/www/html/mlnxos-ztp.sh

# DHCP server: only start if explicitly enabled via DHCP_AUTOSTART=true
# By default DHCP is OFF — admin enables from Provision → DHCP Server → Start
if [ "${DHCP_AUTOSTART:-false}" = "true" ] && [ -f /etc/dhcp/dhcpd.conf ]; then
    DHCP_IFACE="eth0"
    if [ -f /etc/default/isc-dhcp-server ]; then
        DHCP_IFACE=$(grep '^INTERFACES=' /etc/default/isc-dhcp-server 2>/dev/null | sed 's/INTERFACES="//;s/"//' || echo "eth0")
    fi
    dhcpd -cf /etc/dhcp/dhcpd.conf "$DHCP_IFACE" 2>/dev/null && echo "✓ DHCP server started (interface: $DHCP_IFACE)" || echo "  DHCP: not started (interface issue)"
else
    echo "  DHCP: not started (start from Provision page or set DHCP_AUTOSTART=true)"
fi

# ─── SSH Server Setup ───
echo "lldpq:lldpq" | chpasswd 2>/dev/null

# ─── Start Services ───
echo ""
echo "Starting services..."

# Start cron
service cron start > /dev/null 2>&1
echo "  ✓ cron"

# Start fcgiwrap (CGI scripts for web API)
/usr/sbin/fcgiwrap -f -s unix:/var/run/fcgiwrap.socket &
sleep 0.5
chown www-data:www-data /var/run/fcgiwrap.socket
chmod 660 /var/run/fcgiwrap.socket
echo "  ✓ fcgiwrap"

# Start SSH server (port 2033)
/usr/sbin/sshd 2>/dev/null && echo "  ✓ sshd (port 2033)" || echo "  ⚠ sshd failed to start"

# Start console PTY bridge (web SSH terminal, admin-gated) as www-data
mkdir -p /var/log/lldpq 2>/dev/null && chown www-data:www-data /var/log/lldpq 2>/dev/null || true
runuser -u www-data -- python3 /home/lldpq/lldpq/console-pty.py >> /var/log/lldpq/console.log 2>&1 &
echo "  ✓ console-pty (127.0.0.1:8765)"

# Start nginx (foreground - keeps container alive)
echo "  ✓ nginx (port 80)"
echo ""
echo "LLDPq-IB is ready! Access: http://localhost:${LLDPQ_PORT:-80}"
echo "  SSH: ssh -p 2033 lldpq@<host-ip>"
echo ""

exec nginx -g 'daemon off;'
