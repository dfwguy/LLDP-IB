#!/usr/bin/env python3
"""LLDPq-IB Alert Engine.

Runs every 10 minutes (cron via `bin/lldpq`). Reads the IB JSON outputs
produced by `process_ib_*.py` and the local `assets.ini`, applies severity
thresholds, and notifies the channels configured in `notifications.yaml`.

Compared to the LLDPq (Ethernet) check_alerts.py:
  - Removed: BGP, link-flap-from-Eth, optical-from-ethtool, lldp_results.ini.
  - Kept:    state directory, throttling, Slack webhook, severity templating.
  - Added:   SM master loss, IB link error severity, unreachable switches,
             log severity from log_summary.json (still process_log_data.py
             driven), hardware (still applies — MLNX-OS reports temp/fan).
"""

from __future__ import annotations

import datetime
import json
import os
import re
import sys
import time
from pathlib import Path

import requests
import yaml


class LLDPqIBAlerts:
    # ---- lifecycle ------------------------------------------------------

    def __init__(self, script_dir: str):
        self.script_dir = Path(script_dir)
        self.config_file = self.script_dir / "notifications.yaml"
        self.state_dir = self.script_dir / "alert-states"
        self.monitor_results = self.script_dir / "monitor-results"
        self.assets_ini = self.script_dir / "assets.ini"
        # Fall back to /var/www/html/assets.ini if local copy missing
        if not self.assets_ini.exists():
            self.assets_ini = Path("/var/www/html/assets.ini")

        self.state_dir.mkdir(parents=True, exist_ok=True)
        self.config = self._load_config()

    def _load_config(self):
        if not self.config_file.exists():
            print(f"❌ Configuration file not found: {self.config_file}")
            return None
        try:
            with open(self.config_file) as f:
                cfg = yaml.safe_load(f) or {}
        except Exception as e:
            print(f"❌ Error loading config: {e}")
            return None
        if not cfg.get("notifications", {}).get("enabled", False):
            print("Notifications disabled in config")
            return None
        return cfg

    # ---- state / throttling --------------------------------------------

    def _get_state(self, device: str, alert_type: str) -> str:
        p = self.state_dir / f"{device}_{alert_type}.state"
        if p.exists():
            try:
                return p.read_text().strip()
            except Exception:
                return "UNKNOWN"
        return "UNKNOWN"

    def _set_state(self, device: str, alert_type: str, state: str) -> None:
        try:
            (self.state_dir / f"{device}_{alert_type}.state").write_text(state)
        except Exception as e:
            print(f"❌ State write failed for {device}/{alert_type}: {e}")

    def _should_send(self, device: str, alert_type: str, current: str) -> bool:
        if not self.config:
            return False
        if current == self._get_state(device, alert_type):
            return False
        ts_file = self.state_dir / f"{device}_{alert_type}.timestamp"
        min_interval = self.config.get("frequency", {}).get("min_interval_minutes", 30) * 60
        if ts_file.exists():
            try:
                last = float(ts_file.read_text().strip())
                if time.time() - last < min_interval:
                    return False
            except Exception:
                pass
        try:
            ts_file.write_text(str(time.time()))
        except Exception:
            pass
        return True

    # ---- notification dispatch -----------------------------------------

    SEV_COLOR = {
        "CRITICAL":  "#FF0000",
        "WARNING":   "#FFA500",
        "INFO":      "#0066CC",
        "RECOVERED": "#00AA00",
    }

    def _notify(self, title: str, message: str, severity: str, device: str) -> None:
        if not self.config:
            return
        color = self.SEV_COLOR.get(severity, "#808080")
        timestamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        slack_cfg = self.config.get("notifications", {}).get("slack", {})
        if slack_cfg.get("enabled") and slack_cfg.get("webhook"):
            self._send_slack(title, message, color, device, timestamp, slack_cfg)
        else:
            # Console fallback so cron output captures something useful
            print(f"[{severity}] {device}: {title} — {message}")

    def _send_slack(self, title, message, color, device, timestamp, slack_cfg):
        server_url = self.config.get("notifications", {}).get("server_url", "http://localhost")
        payload = {
            "channel":    slack_cfg.get("channel", "#lldpq"),
            "username":   slack_cfg.get("username", "LLDPq-IB Bot"),
            "icon_emoji": slack_cfg.get("icon_emoji", ":warning:"),
            "attachments": [{
                "color": color,
                "title": title,
                "text":  message,
                "fields": [
                    {"title": "Device", "value": device,    "short": True},
                    {"title": "Time",   "value": timestamp, "short": True},
                ],
                "actions": [{
                    "type": "button",
                    "text": "Open device",
                    "url":  f"{server_url}/device.html?device={device}",
                }],
            }],
        }
        try:
            r = requests.post(slack_cfg["webhook"], json=payload, timeout=10)
            if r.status_code == 200:
                print(f"Slack alert sent: {title}")
            else:
                print(f"❌ Slack alert failed: {r.status_code}")
        except Exception as e:
            print(f"❌ Slack notification error: {e}")

    # ---- IB-specific checks --------------------------------------------

    def _load_json(self, name: str):
        path = self.monitor_results / name
        if not path.exists():
            return None
        try:
            with open(path) as f:
                return json.load(f)
        except Exception as e:
            print(f"❌ {name}: {e}")
            return None

    def check_sm_status(self) -> None:
        """Fabric-wide alert: zero Masters, multiple Masters, or master flip."""
        if not self.config.get("alert_types", {}).get("network_alerts", True):
            return
        sm = self._load_json("ib_sm_status.json")
        if not sm:
            return

        sms = sm.get("sms", [])
        masters = [s for s in sms if (s.get("state") or "").lower() == "master"]
        disagreements = sm.get("disagreements") or sm.get("summary", {}).get("disagreement_count", 0)

        if not masters:
            state = "CRITICAL"
            title = "Subnet Manager: NO MASTER"
            msg = "No SM is currently Master. Fabric routing/subnet management at risk."
        elif len(masters) > 1:
            state = "CRITICAL"
            guids = ", ".join(m.get("guid", "?") for m in masters)
            title = "Subnet Manager: MULTIPLE MASTERS"
            msg = f"More than one SM is claiming Master: {guids}"
        elif disagreements:
            state = "WARNING"
            title = "Subnet Manager: disagreement"
            msg = f"{disagreements} SM disagreement(s) detected"
        else:
            state = "OK"
            title = "Subnet Manager OK"
            msg = f"Master: {masters[0].get('guid', '?')}, "\
                  f"{len(sms) - 1} standby"

        if self._should_send("fabric", "sm_status", state):
            severity = "RECOVERED" if state == "OK" else state
            self._notify(title, msg, severity, "fabric")
            self._set_state("fabric", "sm_status", state)

    def check_ib_link_errors(self) -> None:
        """Fabric-wide alert: count of WARNING / CRITICAL ports."""
        if not self.config.get("alert_types", {}).get("network_alerts", True):
            return
        data = self._load_json("ib_link_errors.json")
        if not data:
            return
        s = data.get("summary", {})
        crit = int(s.get("critical") or s.get("critical_count") or 0)
        warn = int(s.get("warning") or s.get("warning_count") or 0)

        if crit:
            state = "CRITICAL"
            title = "IB Link Errors: CRITICAL ports"
            msg = f"{crit} port(s) in CRITICAL link-error state, {warn} WARNING"
        elif warn:
            state = "WARNING"
            title = "IB Link Errors: WARNING ports"
            msg = f"{warn} port(s) in WARNING link-error state"
        else:
            state = "OK"
            title = "IB Link Errors clear"
            msg = "All monitored IB ports are healthy"

        if self._should_send("fabric", "ib_link_errors", state):
            severity = "RECOVERED" if state == "OK" else state
            self._notify(title, msg, severity, "fabric")
            self._set_state("fabric", "ib_link_errors", state)

    def check_unreachable_devices(self) -> None:
        """Per-device alert: device became unreachable since last assets pass."""
        if not self.assets_ini.exists():
            return
        try:
            content = self.assets_ini.read_text()
        except Exception:
            return
        for line in content.splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) < 2:
                continue
            hostname = parts[0]
            status = parts[-1].strip()
            current = "OK" if status == "1" else "UNREACHABLE"
            if self._should_send(hostname, "reachable", current):
                if current == "UNREACHABLE":
                    self._notify(
                        f"{hostname} unreachable",
                        "Device did not respond to the last reachability probe.",
                        "CRITICAL", hostname)
                else:
                    if self.config.get("frequency", {}).get("send_recovery", True):
                        self._notify(
                            f"{hostname} reachable again",
                            "Device responded to the reachability probe.",
                            "RECOVERED", hostname)
                self._set_state(hostname, "reachable", current)

    def check_log_summary(self) -> None:
        """Fabric-wide alert: critical log severity counts."""
        if not self.config.get("alert_types", {}).get("log_alerts", True):
            return
        data = self._load_json("log_summary.json")
        if not data:
            return
        critical = int(data.get("critical") or 0)
        if critical > 0:
            state = "CRITICAL"
            title = "Critical entries in switch logs"
            msg = f"{critical} critical log entries this collection window"
        else:
            state = "OK"
            title = "Switch logs clear"
            msg = "No critical entries"

        if self._should_send("fabric", "log_severity", state):
            severity = "RECOVERED" if state == "OK" else state
            self._notify(title, msg, severity, "fabric")
            self._set_state("fabric", "log_severity", state)

    def check_hardware(self) -> None:
        """Per-device alert: temperature / fan thresholds (parses hardware-data
        text files produced by ib-monitor.sh IB_HARDWARE section)."""
        if not self.config.get("alert_types", {}).get("hardware_alerts", True):
            return
        hw_dir = self.monitor_results / "hardware-data"
        if not hw_dir.exists():
            return
        thresholds = self.config.get("thresholds", {}).get("hardware", {})
        cpu_crit = thresholds.get("cpu_temp_critical", 85)
        cpu_warn = thresholds.get("cpu_temp_warning", 75)
        fan_crit = thresholds.get("fan_rpm_critical", 3000)
        fan_warn = thresholds.get("fan_rpm_warning", 4000)

        for hw_file in hw_dir.glob("*_hardware.txt"):
            device = hw_file.stem.replace("_hardware", "")
            try:
                text = hw_file.read_text()
            except Exception:
                continue

            # CPU temperature (MLNX-OS `show temperature` or `sensors`-style)
            cpu_match = re.search(r"CPU[^\n]*?(-?\d+(?:\.\d+)?)\s*[°]?C", text, re.IGNORECASE)
            if not cpu_match:
                cpu_match = re.search(r"Core\s+\d+:\s*\+?(\d+(?:\.\d+)?)°C", text)
            if cpu_match:
                cpu_t = float(cpu_match.group(1))
                if cpu_t >= cpu_crit:
                    state = "CRITICAL"
                elif cpu_t >= cpu_warn:
                    state = "WARNING"
                else:
                    state = "OK"
                if self._should_send(device, "cpu_temp", state):
                    sev = "RECOVERED" if state == "OK" else state
                    self._notify(
                        f"{device} CPU temperature {state}",
                        f"CPU temperature: {cpu_t}°C (crit {cpu_crit}, warn {cpu_warn})",
                        sev, device)
                    self._set_state(device, "cpu_temp", state)

            # Fan RPM
            min_rpm = None
            for fan_match in re.finditer(r"(?:FAN|Fan)\s*\d+\D+(\d{2,5})\s*RPM", text):
                rpm = int(fan_match.group(1))
                if min_rpm is None or rpm < min_rpm:
                    min_rpm = rpm
            if min_rpm is not None:
                if min_rpm <= fan_crit:
                    state = "CRITICAL"
                elif min_rpm <= fan_warn:
                    state = "WARNING"
                else:
                    state = "OK"
                if self._should_send(device, "fan_rpm", state):
                    sev = "RECOVERED" if state == "OK" else state
                    self._notify(
                        f"{device} fan speed {state}",
                        f"Lowest fan RPM: {min_rpm} (crit ≤{fan_crit}, warn ≤{fan_warn})",
                        sev, device)
                    self._set_state(device, "fan_rpm", state)

    # ---- entry ----------------------------------------------------------

    def run(self) -> None:
        if not self.config:
            return
        print("LLDPq-IB alert check starting (fabric + per-device)...")
        self.check_sm_status()
        self.check_ib_link_errors()
        self.check_log_summary()
        self.check_unreachable_devices()
        self.check_hardware()
        print("LLDPq-IB alert check complete.")


def main() -> None:
    script_dir = os.path.dirname(os.path.abspath(__file__))
    alerts = LLDPqIBAlerts(script_dir)
    if len(sys.argv) > 1 and sys.argv[1] != "-":
        # Debug: only run one device's hardware check
        device = sys.argv[1]
        print(f"Debug: checking hardware for {device}")
        alerts.check_hardware()
    else:
        alerts.run()


if __name__ == "__main__":
    main()
