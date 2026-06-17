#!/usr/bin/env python3
"""
Process IB QoS profile data collected by ib-monitor.sh

Parses legacy MLNX-OS QoS-profile text to aggregate Service Level (SL)
to Virtual Lane (VL) mappings and QoS profiles across switches.

Copyright (c) 2024-2026 LLDPq Project
Licensed under MIT License - see LICENSE file for details
"""

import os
import re
import json
from datetime import datetime


# Legacy MLNX-OS QoS-profile text (varies between versions). Approximate form:
#
#   Profile Name : default
#       Traffic Class: 0
#       SL2VL mapping:
#           SL 0 -> VL 0
#           SL 1 -> VL 1
#           ...
#       VL Arbitration:
#           ...
#
# Some versions list profiles with different fields; we capture what we can
# heuristically and leave room for future refinement.


_PROFILE_RE = re.compile(r'^\s*Profile\s+Name\s*:\s*(\S+)', re.IGNORECASE)
_TC_RE      = re.compile(r'^\s*Traffic\s+Class\s*:\s*(\d+)', re.IGNORECASE)
_SL2VL_RE   = re.compile(r'^\s*SL\s+(\d+)\s*->\s*VL\s+(\d+)', re.IGNORECASE)


def parse_qos(filepath):
    """Parse legacy QoS-profile text into a list of profile dicts."""
    if not os.path.exists(filepath):
        return []
    
    profiles = []
    current = None
    
    try:
        with open(filepath, 'r') as f:
            for line in f:
                m = _PROFILE_RE.match(line)
                if m:
                    if current:
                        profiles.append(current)
                    current = {
                        'name': m.group(1),
                        'traffic_class': '',
                        'sl_to_vl': {},
                    }
                    continue
                
                if not current:
                    continue
                
                m = _TC_RE.match(line)
                if m:
                    current['traffic_class'] = m.group(1)
                    continue
                
                m = _SL2VL_RE.match(line)
                if m:
                    sl, vl = m.group(1), m.group(2)
                    current['sl_to_vl'][sl] = vl
    except Exception:
        pass
    
    if current:
        profiles.append(current)
    return profiles


def process_qos(data_dir='monitor-results/ib-qos',
                output_dir='monitor-results'):
    """Aggregate per-switch QoS profiles. Detects mismatches in SL/VL mapping."""
    if not os.path.isdir(data_dir):
        print(f"No IB QoS data dir: {data_dir}")
        return
    
    per_device = {}
    profile_seen = {}  # name -> list of (hostname, profile)
    
    for filename in sorted(os.listdir(data_dir)):
        if not filename.endswith('.txt'):
            continue
        hostname = filename[:-4]
        profiles = parse_qos(os.path.join(data_dir, filename))
        per_device[hostname] = profiles
        
        for p in profiles:
            profile_seen.setdefault(p['name'], []).append({
                'hostname': hostname,
                'traffic_class': p['traffic_class'],
                'sl_to_vl': p['sl_to_vl'],
            })
    
    # Build summary
    profile_list = []
    inconsistencies = []
    for name, occurrences in sorted(profile_seen.items()):
        # All occurrences should have the same SL/VL mapping; flag if not
        first_mapping = occurrences[0]['sl_to_vl'] if occurrences else {}
        all_same = all(o['sl_to_vl'] == first_mapping for o in occurrences)
        
        record = {
            'name': name,
            'devices': sorted(set(o['hostname'] for o in occurrences)),
            'device_count': len(occurrences),
            'sl_to_vl': first_mapping,
            'consistent': all_same,
        }
        profile_list.append(record)
        if not all_same:
            inconsistencies.append(record)
    
    result = {
        'last_update': datetime.now().isoformat(),
        'profiles': profile_list,
        'per_device': per_device,
        'summary': {
            'total_profiles': len(profile_list),
            'devices_polled': len(per_device),
            'inconsistencies': len(inconsistencies),
        }
    }
    
    output_path = os.path.join(output_dir, 'ib_qos.json')
    with open(output_path, 'w') as f:
        json.dump(result, f, indent=2)
    
    print(f"IB QoS: {len(profile_list)} profiles across "
          f"{len(per_device)} devices, {len(inconsistencies)} inconsistencies")


if __name__ == '__main__':
    process_qos()
