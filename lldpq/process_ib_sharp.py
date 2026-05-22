#!/usr/bin/env python3
"""
Process IB SHARP (Scalable Hierarchical Aggregation and Reduction Protocol) data
collected by ib-monitor.sh.

Parses MLNX-OS 'show ib sharp aggregation-nodes' output. SHARP is conditional --
if not enabled on the switch, the marker section contains "SHARP_NOT_AVAILABLE"
and we emit a disabled status JSON.

The web UI uses ib_sharp_status.json's "enabled" field to decide whether to
show the SHARP menu item.

Copyright (c) 2024-2026 LLDPq Project
Licensed under MIT License - see LICENSE file for details
"""

import os
import re
import json
from datetime import datetime


# 'show ib sharp aggregation-nodes' output (when SHARP is enabled):
#
#   Aggregation Node : 0x...guid...
#       Tree ID      : 1
#       Quota        : 64
#       Reservation  : 32
#       ...
#
# When SHARP is disabled, ib-monitor.sh emits a single line: SHARP_NOT_AVAILABLE


_NODE_RE       = re.compile(r'^\s*Aggregation\s+Node\s*:\s*(0x[0-9a-fA-F]+)', re.IGNORECASE)
_TREE_ID_RE    = re.compile(r'^\s*Tree\s+ID\s*:\s*(\d+)', re.IGNORECASE)
_QUOTA_RE      = re.compile(r'^\s*Quota\s*:\s*(\d+)', re.IGNORECASE)
_RESERVATION_RE = re.compile(r'^\s*Reservation\s*:\s*(\d+)', re.IGNORECASE)


def parse_sharp(filepath):
    """Parse 'show ib sharp aggregation-nodes'. Returns (enabled, nodes).
    
    enabled = False if file is missing/empty or contains 'SHARP_NOT_AVAILABLE'.
    """
    if not os.path.exists(filepath):
        return False, []
    
    try:
        with open(filepath, 'r') as f:
            content = f.read()
    except Exception:
        return False, []
    
    if not content.strip() or 'SHARP_NOT_AVAILABLE' in content:
        return False, []
    
    nodes = []
    current = None
    for line in content.splitlines():
        m = _NODE_RE.match(line)
        if m:
            if current:
                nodes.append(current)
            current = {'guid': m.group(1).lower(), 'tree_id': '', 'quota': '', 'reservation': ''}
            continue
        if not current:
            continue
        m = _TREE_ID_RE.match(line)
        if m:
            current['tree_id'] = m.group(1)
            continue
        m = _QUOTA_RE.match(line)
        if m:
            current['quota'] = m.group(1)
            continue
        m = _RESERVATION_RE.match(line)
        if m:
            current['reservation'] = m.group(1)
    
    if current:
        nodes.append(current)
    
    return True, nodes


def process_sharp(data_dir='monitor-results/ib-sharp',
                  output_dir='monitor-results'):
    """Aggregate per-switch SHARP info. Output drives the sidebar menu visibility."""
    if not os.path.isdir(data_dir):
        result = {
            'last_update': datetime.now().isoformat(),
            'enabled': False,
            'nodes': [],
            'per_device': {},
            'summary': {'devices_with_sharp': 0, 'total_aggregation_nodes': 0},
        }
        with open(os.path.join(output_dir, 'ib_sharp_status.json'), 'w') as f:
            json.dump(result, f, indent=2)
        print("IB SHARP: data dir missing, status=disabled")
        return
    
    per_device = {}
    all_nodes = {}  # guid -> node dict
    devices_with_sharp = 0
    
    for filename in sorted(os.listdir(data_dir)):
        if not filename.endswith('.txt'):
            continue
        hostname = filename[:-4]
        enabled, nodes = parse_sharp(os.path.join(data_dir, filename))
        per_device[hostname] = {'enabled': enabled, 'node_count': len(nodes)}
        if enabled:
            devices_with_sharp += 1
        for n in nodes:
            all_nodes[n['guid']] = n
    
    fabric_enabled = devices_with_sharp > 0
    
    result = {
        'last_update': datetime.now().isoformat(),
        'enabled': fabric_enabled,
        'nodes': list(all_nodes.values()),
        'per_device': per_device,
        'summary': {
            'devices_with_sharp': devices_with_sharp,
            'total_aggregation_nodes': len(all_nodes),
        }
    }
    
    output_path = os.path.join(output_dir, 'ib_sharp_status.json')
    with open(output_path, 'w') as f:
        json.dump(result, f, indent=2)
    
    print(f"IB SHARP: enabled={fabric_enabled}, "
          f"devices_with_sharp={devices_with_sharp}, "
          f"aggregation_nodes={len(all_nodes)}")


if __name__ == '__main__':
    process_sharp()
