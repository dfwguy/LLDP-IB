#!/usr/bin/env python3
"""
IB Link Error Analyzer

Tracks IB performance counters across monitoring cycles and detects:
- Link flaps via LinkDownedCounter increments
- Increasing SymbolErrors / PortRcvErrors trends
- Sudden spikes (counter delta > threshold)

Stored history per port (device:port) in ib_link_history.json so we can
compute deltas between cycles.

Copyright (c) 2024-2026 LLDPq Project
Licensed under MIT License - see LICENSE file for details
"""

import os
import json
import time
import collections
from typing import Dict, List


# Counters we track from perfquery / ibqueryerrors output
TRACKED_COUNTERS = [
    'LinkDownedCounter',
    'SymbolErrorCounter',
    'LinkErrorRecoveryCounter',
    'PortRcvErrors',
    'PortRcvSwitchRelayErrors',
    'PortXmitDiscards',
    'PortRcvConstraintErrors',
    'PortXmitConstraintErrors',
    'PortRcvSwitchRelayErrors',
    'ExcessiveBufferOverrunErrors',
    'VL15Dropped',
    'PortXmitWait',
]

# Severity thresholds (per cycle delta)
THRESHOLDS = {
    'LinkDownedCounter':       {'warning': 1,    'critical': 5},
    'SymbolErrorCounter':      {'warning': 100,  'critical': 1000},
    'LinkErrorRecoveryCounter':{'warning': 5,    'critical': 20},
    'PortRcvErrors':           {'warning': 10,   'critical': 100},
    'PortXmitDiscards':        {'warning': 100,  'critical': 1000},
}

# Lifetime alert hold (older than this, treated as "history")
ALERT_PERSIST_SECONDS = 60 * 60  # 1 hour
HISTORY_RETENTION_SECONDS = 24 * 60 * 60  # 24 hours


class IbLinkAnalyzer:
    """Tracks IB link counters and detects anomalies."""
    
    def __init__(self, data_dir: str = 'monitor-results'):
        self.data_dir = data_dir
        self.history_file = os.path.join(data_dir, 'ib_link_history.json')
        self.current: Dict[str, Dict[str, int]] = {}     # port_key -> {counter: value}
        self.previous: Dict[str, Dict[str, int]] = {}    # port_key -> {counter: value}
        self.deltas: Dict[str, Dict[str, int]] = {}      # port_key -> {counter: delta_since_previous}
        self.flap_history: Dict[str, collections.deque] = {}  # port_key -> deque[(ts, link_downed)]
        self.last_update: float = 0.0
        
        self._load_history()
    
    def _load_history(self):
        """Load previous cycle counters from history file."""
        if not os.path.exists(self.history_file):
            return
        try:
            with open(self.history_file, 'r') as f:
                data = json.load(f)
            self.previous = data.get('current', {})
            self.last_update = float(data.get('last_update', 0))
            for port_key, events in data.get('flap_history', {}).items():
                self.flap_history[port_key] = collections.deque(events, maxlen=1000)
        except Exception:
            pass
    
    def save_history(self):
        """Persist current state for next cycle to compare against."""
        now = time.time()
        # Trim old flap history
        cutoff = now - HISTORY_RETENTION_SECONDS
        for port_key, queue in self.flap_history.items():
            while queue and queue[0][0] < cutoff:
                queue.popleft()
        
        data = {
            'last_update': now,
            'current': self.current,
            'flap_history': {k: list(v) for k, v in self.flap_history.items()},
        }
        os.makedirs(self.data_dir, exist_ok=True)
        with open(self.history_file, 'w') as f:
            json.dump(data, f, indent=2)
    
    def update(self, hostname: str, port: str, counters: Dict[str, int]):
        """Record current counter snapshot for a port on a device."""
        port_key = f"{hostname}:{port}"
        self.current[port_key] = dict(counters)
        
        # Compute delta vs previous cycle (only for tracked counters)
        if port_key in self.previous:
            delta = {}
            for c in TRACKED_COUNTERS:
                cur = counters.get(c, 0)
                prev = self.previous[port_key].get(c, 0)
                if isinstance(cur, (int, float)) and isinstance(prev, (int, float)):
                    diff = cur - prev
                    if diff > 0:
                        delta[c] = diff
            if delta:
                self.deltas[port_key] = delta
            
            # Track flaps explicitly via LinkDownedCounter
            ld_delta = delta.get('LinkDownedCounter', 0)
            if ld_delta > 0:
                self.flap_history.setdefault(port_key, collections.deque(maxlen=1000))
                self.flap_history[port_key].append((time.time(), ld_delta))
    
    def severity(self, port_key: str) -> str:
        """Return 'critical', 'warning', or 'normal' for a port based on deltas."""
        delta = self.deltas.get(port_key, {})
        worst = 'normal'
        for counter, value in delta.items():
            t = THRESHOLDS.get(counter)
            if not t:
                continue
            if value >= t['critical']:
                return 'critical'
            elif value >= t['warning']:
                worst = 'warning'
        return worst
    
    def flap_count(self, port_key: str, since_seconds: int = 3600) -> int:
        """Count flaps for a port in the last N seconds."""
        if port_key not in self.flap_history:
            return 0
        cutoff = time.time() - since_seconds
        return sum(d for ts, d in self.flap_history[port_key] if ts >= cutoff)
    
    def top_problem_ports(self, limit: int = 20) -> List[Dict]:
        """Return ports with worst severity for UI display."""
        result = []
        for port_key, delta in self.deltas.items():
            sev = self.severity(port_key)
            if sev == 'normal':
                continue
            hostname, port = port_key.split(':', 1)
            result.append({
                'device': hostname,
                'port': port,
                'severity': sev,
                'delta': delta,
                'current': self.current.get(port_key, {}),
                'flaps_1h': self.flap_count(port_key, 3600),
                'flaps_24h': self.flap_count(port_key, 24 * 3600),
            })
        # critical first, then by largest LinkDowned delta
        order = {'critical': 0, 'warning': 1}
        result.sort(key=lambda p: (order.get(p['severity'], 9),
                                    -p['delta'].get('LinkDownedCounter', 0),
                                    -sum(p['delta'].values())))
        return result[:limit]
