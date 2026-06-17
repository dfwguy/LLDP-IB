#!/usr/bin/env python3
"""
Process IB Multicast Groups data collected by ib-monitor.sh

Parses legacy SA multicast text output and aggregates multicast group membership.
Used to track IPoIB / MPI / NCCL multicast groups across the fabric.

Multicast groups are SM-managed and fabric-wide, so we can use any single
switch's view as authoritative (we still aggregate to be resilient).

Copyright (c) 2024-2026 LLDPq Project
Licensed under MIT License - see LICENSE file for details
"""

import os
import re
import json
from datetime import datetime


# Legacy SA multicast output (one block per multicast group):
#
#   MCMemberRecord group dump:
#       MGID....................ff12:401b:ffff:0000:0000:0000:ffff:ffff
#       Mlid....................0xc000
#       Mtu.....................0x84
#       pkey....................0x7fff
#       Rate....................0x86
#       SL......................0
#       FlowLabel...............0x0
#       HopLimit................0xff
#       TClass..................0x0


_FIELD_RE = re.compile(r'^\s*(\w+)[\.:]+\s*(\S+)')
_GROUP_HEADER_RE = re.compile(r'MCMemberRecord\s+group\s+dump', re.IGNORECASE)


def parse_multicast(filepath):
    """Parse legacy SA multicast text. Returns list of multicast group dicts."""
    if not os.path.exists(filepath):
        return []
    
    groups = []
    current = None
    
    try:
        with open(filepath, 'r') as f:
            for line in f:
                if _GROUP_HEADER_RE.search(line):
                    if current is not None:
                        groups.append(current)
                    current = {}
                    continue
                
                if current is None:
                    continue
                
                m = _FIELD_RE.match(line)
                if m:
                    key = m.group(1).lower()
                    val = m.group(2).strip()
                    current[key] = val
    except Exception:
        pass
    
    if current is not None:
        groups.append(current)
    
    # Normalize fields we care about
    normalized = []
    for g in groups:
        normalized.append({
            'mgid': g.get('mgid', ''),
            'mlid': g.get('mlid', ''),
            'pkey': g.get('pkey', ''),
            'mtu': g.get('mtu', ''),
            'rate': g.get('rate', ''),
            'sl': g.get('sl', ''),
            'tclass': g.get('tclass', ''),
            'flowlabel': g.get('flowlabel', ''),
            'hoplimit': g.get('hoplimit', ''),
        })
    return normalized


def process_multicast(data_dir='monitor-results/ib-multicast',
                      output_dir='monitor-results'):
    """Aggregate per-switch multicast group views."""
    if not os.path.isdir(data_dir):
        print(f"No IB multicast data dir: {data_dir}")
        return
    
    all_groups = {}    # mlid -> group dict (deduplicate across devices)
    per_device_count = {}  # hostname -> count
    
    for filename in sorted(os.listdir(data_dir)):
        if not filename.endswith('.txt'):
            continue
        hostname = filename[:-4]
        groups = parse_multicast(os.path.join(data_dir, filename))
        per_device_count[hostname] = len(groups)
        
        for g in groups:
            mlid = g.get('mlid', '')
            if not mlid:
                continue
            if mlid not in all_groups:
                all_groups[mlid] = dict(g)
                all_groups[mlid]['observed_by'] = [hostname]
            else:
                all_groups[mlid]['observed_by'].append(hostname)
    
    # Sort by MLID numeric value
    group_list = sorted(all_groups.values(),
                         key=lambda g: int(g.get('mlid', '0x0'), 16))
    
    # Group by P_Key for summary
    pkey_distribution = {}
    for g in group_list:
        pk = g.get('pkey', 'unknown')
        pkey_distribution[pk] = pkey_distribution.get(pk, 0) + 1
    
    result = {
        'last_update': datetime.now().isoformat(),
        'groups': group_list,
        'summary': {
            'total_groups': len(group_list),
            'devices_polled': len(per_device_count),
            'pkey_distribution': pkey_distribution,
        }
    }
    
    output_path = os.path.join(output_dir, 'ib_multicast.json')
    with open(output_path, 'w') as f:
        json.dump(result, f, indent=2)
    
    print(f"IB multicast: {len(group_list)} groups across "
          f"{len(per_device_count)} devices")


if __name__ == '__main__':
    process_multicast()
