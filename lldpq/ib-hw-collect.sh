#!/usr/bin/env bash
# ib-hw-collect.sh - Switch hardware collector for CLI-only MLNX-OS switches.
#
# The fabric-wide data (topology, SM, links, pkeys) comes from UFM via
# ufm-adapter.py. This script adds the switch-LOCAL hardware that UFM does not
# expose well: CPU/ASIC temperature, fans, PSU power, plus identity
# (serial / MLNX-OS release / uptime) to enrich assets.ini.
#
# MLNX-OS admin accounts are CLI-only (no SSH shell, no `ib`-utils prefix), so we
# drive an interactive enable-mode CLI session over key-based SSH and normalize
# `show temperature|fan|power|inventory|version` into the line format that
# generate_hardware_html.py already parses (Ambient ASIC Temp / Core N / *Fan*
# RPM / PSU rail Pwr (in) / Mem: / CPU_INFO).
#
# Requires the lldpq SSH key to be authorized on the switches (send-key.sh /
# Provision SSH Setup). Run as the lldpq user (cron) so the key is used directly.
#
# Copyright (c) 2024-2026 LLDPq Project - Licensed under MIT License

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
eval "$(python3 "$SCRIPT_DIR/parse_devices.py")"
source /etc/lldpq.conf 2>/dev/null || true
WEB_ROOT="${WEB_ROOT:-/var/www/html}"
LLDPQ_USER="${LLDPQ_USER:-${USER:-lldpq}}"

RESULTS="$SCRIPT_DIR/monitor-results"
HWDIR="$RESULTS/hardware-data"
RAWDIR="$RESULTS/hw-raw"
IDENTITY="$RESULTS/switch_identity.json"
mkdir -p "$HWDIR" "$RAWDIR"

KEY="${HOME}/.ssh/id_rsa"
[ -f "$KEY" ] || KEY="${HOME}/.ssh/id_ed25519"
MAXP="${HW_MAX_PARALLEL:-10}"

SSH_OPTS=(-i "$KEY" -tt -o BatchMode=yes -o StrictHostKeyChecking=no
          -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR)

# One interactive enable-mode session per switch; capture all five show commands.
collect_one() {
    local dev=$1 user=$2 host=$3
    printf 'enable\nno cli session paging enable\nshow version\nshow inventory\nshow temperature\nshow fan\nshow power\nexit\nexit\n' \
        | timeout 45 ssh "${SSH_OPTS[@]}" "${user}@${dev}" 2>/dev/null \
        | tr -d '\r' > "$RAWDIR/${host}.txt" || true
}

echo "Collecting switch hardware from ${#devices[@]} devices (key auth, max parallel: $MAXP)..."
running=0
for dev in "${!devices[@]}"; do
    IFS=' ' read -r user host <<< "${devices[$dev]}"
    collect_one "$dev" "$user" "$host" &
    running=$((running+1))
    if [ "$running" -ge "$MAXP" ]; then wait -n 2>/dev/null || wait; running=$((running-1)); fi
done
wait

# Parse raw CLI output -> normalized hardware files + identity JSON.
python3 - "$RAWDIR" "$HWDIR" "$IDENTITY" <<'PY'
import json, os, re, sys
rawdir, hwdir, identity_path = sys.argv[1], sys.argv[2], sys.argv[3]
identity = {}

def mb_to_gi(mb):
    try:
        return f"{float(mb)/1024.0:.1f}Gi"
    except Exception:
        return "0Gi"

for fn in sorted(os.listdir(rawdir)):
    if not fn.endswith(".txt"):
        continue
    host = fn[:-4]
    text = open(os.path.join(rawdir, fn), errors="replace").read()
    if not text.strip():
        continue

    out = [f"# LLDPq-IB hardware (MLNX-OS CLI, normalized) for {host}"]

    # ---- identity / version ----
    rel = (re.search(r'Product release:\s*(\S+)', text) or [None, ""])[1]
    uptime = (re.search(r'Uptime:\s*(.+)', text) or [None, ""])[1].strip()
    serial = (re.search(r'System serial num:\s*(\S+)', text) or [None, ""])[1]
    # inventory CHASSIS row: "CHASSIS  <part>  <serial> ..." -- the part number
    # (e.g. MQM9700-NS2F) is the useful model, not "Product model: x86onie".
    model = ""
    m = re.search(r'^\s*CHASSIS\s+(\S+)\s+(\S+)', text, re.MULTILINE)
    if m:
        model = m.group(1)
        serial = serial or m.group(2)
    if not model:
        model = (re.search(r'Product model:\s*(\S+)', text) or [None, ""])[1]
    out += [f"Hostname: {host}", f"Model: {model or 'N/A'}",
            f"Serial: {serial or 'N/A'}", f"OS Version: MLNX-OS {rel or 'N/A'}",
            f"Uptime: {uptime or 'N/A'}", ""]

    # ---- temperature: QTM2 = ASIC; CPU Core Sensor = cores; CPU package ----
    asic = re.search(r'QTM\d?\s+\S+\s+([0-9]+\.?[0-9]*)', text)
    if asic:
        out.append(f"Ambient ASIC Temp: +{float(asic.group(1)):.1f}\u00b0C")
    cores = re.findall(r'CPU Core Sensor\s+\S+\s+([0-9]+\.?[0-9]*)', text)
    for i, t in enumerate(cores):
        out.append(f"Core {i}: +{float(t):.1f}\u00b0C")
    pkg = re.search(r'CPU package Sensor\s+\S+\s+([0-9]+\.?[0-9]*)', text)
    if pkg:
        out.append(f"Package id 0: +{float(pkg.group(1)):.1f}\u00b0C")
    out.append("")

    # ---- fans: "FANx FAN Fy <rpm> OK" ----
    for mod, fan, rpm in re.findall(r'^(\S*FAN\S*|PS\d)\s+FAN\s+(F\d)\s+([0-9]+)\.?[0-9]*\s', text, re.MULTILINE):
        out.append(f"{mod}-{fan} Fan: {rpm} RPM")
    out.append("")

    # ---- power: PSU input watts -> emit as 220V Rail Pwr (in) ----
    for ps, watts in re.findall(r'^(PS\d)\s+power-mon\s+input\s+([0-9]+\.?[0-9]*)', text, re.MULTILINE):
        out.append(f"PSU-{ps[-1]} 220V Rail Pwr (in): {watts} W")
    tot = re.search(r'Total power used\s*:\s*([0-9]+\.?[0-9]*)', text)
    if tot:
        out.append(f"Total power used: {tot.group(1)} W")
    out.append("")

    # ---- memory: "System memory: A MB used / B MB free / C MB total" ----
    mem = re.search(r'System memory:\s*([0-9]+)\s*MB used\s*/\s*([0-9]+)\s*MB free\s*/\s*([0-9]+)\s*MB total', text)
    if mem:
        used, free, total = mem.group(1), mem.group(2), mem.group(3)
        out.append(f"Mem: {mb_to_gi(total)} {mb_to_gi(used)} {mb_to_gi(free)} 0Mi 0Mi {mb_to_gi(free)}")

    # ---- cpu load: "CPU load averages: a / b / c" ----
    load = re.search(r'CPU load averages:\s*([0-9.]+)\s*/\s*([0-9.]+)\s*/\s*([0-9.]+)', text)
    if load:
        out += ["CPU_INFO:", f"{load.group(1)} {load.group(2)} {load.group(3)}"]

    open(os.path.join(hwdir, f"{host}_hardware.txt"), "w").write("\n".join(out) + "\n")
    identity[host] = {"serial": serial or "", "release": rel or "",
                      "uptime": uptime or "", "model": model or ""}

json.dump({"generated_at": __import__("datetime").datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S UTC"),
           "switches": identity}, open(identity_path, "w"), indent=2)
print(f"hardware: parsed {len(identity)} switches -> {hwdir}")
PY

# Generate the Hardware Health HTML from the normalized files (best effort).
( cd "$RESULTS" && python3 "$SCRIPT_DIR/generate_hardware_html.py" >/dev/null 2>&1 ) || true

# Publish to web root.
mkdir -p "$WEB_ROOT/monitor-results/hardware-data"
cp -f "$HWDIR"/*.txt "$WEB_ROOT/monitor-results/hardware-data/" 2>/dev/null || true
cp -f "$RESULTS/hardware-analysis.html" "$WEB_ROOT/monitor-results/" 2>/dev/null || true
cp -f "$IDENTITY" "$WEB_ROOT/monitor-results/" 2>/dev/null || true
chown -R "$LLDPQ_USER:www-data" "$WEB_ROOT/monitor-results/hardware-data" 2>/dev/null || true

echo "ib-hw-collect done."
