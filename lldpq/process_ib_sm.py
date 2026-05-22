#!/usr/bin/env python3
"""
Process IB Subnet Manager (SM) data collected by ib-monitor.sh

Parses 'ib sminfo' output from each switch to identify:
- Master SM (state=3)
- Standby SMs (state=2)
- SM priority and capability mask

Each switch may report a different SM as master if the fabric is partitioned
or the master is unreachable from some switches; we use majority vote.

Copyright (c) 2024-2026 LLDPq Project
Licensed under MIT License - see LICENSE file for details
"""

import os
import re
import json
from datetime import datetime
from collections import Counter


# sminfo output example:
#   sminfo: sm lid 1 sm guid 0x0002c90300abc100, activity count 12345 priority 0 state 3 SMINFO_MASTER
#
# Direct routed:
#   sminfo: sm lid 5 sm guid 0x0002c90300def456, activity count 0 priority 1 state 2 SMINFO_STANDBY


STATE_NAMES = {
    0: 'not_active',
    1: 'discovering',
    2: 'standby',
    3: 'master',
}


_SMINFO_RE = re.compile(
    r'sm\s+lid\s+(?P<lid>\d+)\s+'
    r'sm\s+guid\s+(?P<guid>0x[0-9a-fA-F]+)'
    r'.*?priority\s+(?P<priority>\d+)'
    r'.*?state\s+(?P<state>\d+)',
    re.IGNORECASE
)


def parse_sminfo(filepath):
    """Parse a single switch's 'ib sminfo' output. Returns list of SM records."""
    sms = []
    if not os.path.exists(filepath):
        return sms
    
    try:
        with open(filepath, 'r') as f:
            content = f.read()
    except Exception:
        return sms
    
    for m in _SMINFO_RE.finditer(content):
        state = int(m.group('state'))
        sms.append({
            'lid': int(m.group('lid')),
            'guid': m.group('guid').lower(),
            'priority': int(m.group('priority')),
            'state': state,
            'state_name': STATE_NAMES.get(state, 'unknown'),
        })
    
    return sms


def process_sm(data_dir='monitor-results/ib-sm',
               output_dir='monitor-results'):
    """Aggregate per-switch SM views into a fabric-wide picture."""
    if not os.path.isdir(data_dir):
        print(f"No IB SM data dir: {data_dir}")
        return
    
    per_device = {}        # hostname -> list of SM records reported by this device
    master_votes = Counter()  # guid -> times reported as master
    all_sms = {}           # guid -> latest record (any state)
    
    for filename in sorted(os.listdir(data_dir)):
        if not filename.endswith('.txt'):
            continue
        hostname = filename[:-4]
        filepath = os.path.join(data_dir, filename)
        sms = parse_sminfo(filepath)
        per_device[hostname] = sms
        
        for sm in sms:
            all_sms[sm['guid']] = sm
            if sm['state'] == 3:
                master_votes[sm['guid']] += 1
    
    # Determine fabric-wide master (most-reported master)
    master_guid = None
    if master_votes:
        master_guid = master_votes.most_common(1)[0][0]
    
    # Build SM list with role labels
    sm_list = []
    for guid, sm in all_sms.items():
        record = dict(sm)
        if guid == master_guid:
            record['role'] = 'master'
        elif sm['state'] == 2:
            record['role'] = 'standby'
        else:
            record['role'] = sm['state_name']
        sm_list.append(record)
    
    # Sort: master first, then standby by priority desc, then others
    role_order = {'master': 0, 'standby': 1}
    sm_list.sort(key=lambda s: (role_order.get(s['role'], 9),
                                 -s.get('priority', 0),
                                 s.get('lid', 0)))
    
    # Devices that disagree on master
    disagreements = []
    if master_guid:
        for hostname, sms in per_device.items():
            local_master = next((s['guid'] for s in sms if s['state'] == 3), None)
            if local_master and local_master != master_guid:
                disagreements.append({
                    'device': hostname,
                    'local_master': local_master,
                    'fabric_master': master_guid,
                })
    
    result = {
        'last_update': datetime.now().isoformat(),
        'master_guid': master_guid,
        'sms': sm_list,
        'devices_polled': len(per_device),
        'devices_with_master_view': sum(1 for s in per_device.values() if any(x['state'] == 3 for x in s)),
        'disagreements': disagreements,
        'summary': {
            'total_sms': len(all_sms),
            'master_count': sum(1 for s in sm_list if s['role'] == 'master'),
            'standby_count': sum(1 for s in sm_list if s['role'] == 'standby'),
            'has_master': master_guid is not None,
            'has_redundancy': sum(1 for s in sm_list if s['role'] == 'standby') > 0,
        }
    }
    
    output_path = os.path.join(output_dir, 'ib_sm_status.json')
    with open(output_path, 'w') as f:
        json.dump(result, f, indent=2)
    
    print(f"IB SM: master={master_guid or 'NONE'}, "
          f"standby={result['summary']['standby_count']}, "
          f"disagreements={len(disagreements)}")


if __name__ == '__main__':
    process_sm()
