#!/usr/bin/env python3
"""
Process IB P_Key (partition) data collected by ib-monitor.sh

Parses MLNX-OS 'show ib partition' output and aggregates partition
configuration across the fabric. Detects cross-device inconsistencies
(e.g. a P_Key configured on some switches but missing on others).

Copyright (c) 2024-2026 LLDPq Project
Licensed under MIT License - see LICENSE file for details
"""

import os
import re
import json
from datetime import datetime
try:
    import yaml
except Exception:
    yaml = None


# MLNX-OS 'show ib partition' output (varies between versions). Common form:
#
#   Partition Name : management
#       PKey       : 0x7fff
#       IPoIB      : enabled
#       MTU        : 4096
#       Rate       : 200
#       Members    :
#           0x...guid... full
#           0x...guid... limited
#
# We capture: name, pkey (hex), IPoIB flag, MTU, rate, member count and
# member GUIDs with their membership type.


_PART_NAME_RE = re.compile(r'^\s*Partition\s+Name\s*:\s*(\S+)', re.IGNORECASE)
_PKEY_RE      = re.compile(r'^\s*PKey\s*:\s*(0x[0-9a-fA-F]+)', re.IGNORECASE)
_IPOIB_RE     = re.compile(r'^\s*IPoIB\s*:\s*(\S+)', re.IGNORECASE)
_MTU_RE       = re.compile(r'^\s*MTU\s*:\s*(\d+)', re.IGNORECASE)
_RATE_RE      = re.compile(r'^\s*Rate\s*:\s*(\S+)', re.IGNORECASE)
_MEMBERS_HDR  = re.compile(r'^\s*Members\s*:', re.IGNORECASE)
_MEMBER_RE    = re.compile(r'^\s*(0x[0-9a-fA-F]+)\s+(full|limited|both)?', re.IGNORECASE)


def parse_partitions(filepath):
    """Parse 'show ib partition' output into a list of partition dicts."""
    if not os.path.exists(filepath):
        return []
    
    partitions = []
    current = None
    in_members = False
    
    try:
        with open(filepath, 'r') as f:
            for line in f:
                if _PART_NAME_RE.match(line):
                    if current:
                        partitions.append(current)
                    current = {
                        'name': _PART_NAME_RE.match(line).group(1),
                        'pkey': '',
                        'ipoib': False,
                        'mtu': '',
                        'rate': '',
                        'members': [],
                    }
                    in_members = False
                    continue
                
                if not current:
                    continue
                
                m = _PKEY_RE.match(line)
                if m:
                    current['pkey'] = m.group(1).lower()
                    continue
                m = _IPOIB_RE.match(line)
                if m:
                    current['ipoib'] = m.group(1).lower() in ('enabled', 'yes', 'true')
                    continue
                m = _MTU_RE.match(line)
                if m:
                    current['mtu'] = m.group(1)
                    continue
                m = _RATE_RE.match(line)
                if m:
                    current['rate'] = m.group(1)
                    continue
                if _MEMBERS_HDR.match(line):
                    in_members = True
                    continue
                
                if in_members:
                    m = _MEMBER_RE.match(line)
                    if m:
                        current['members'].append({
                            'guid': m.group(1).lower(),
                            'membership': (m.group(2) or 'full').lower(),
                        })
    except Exception:
        pass
    
    if current:
        partitions.append(current)
    return partitions


def process_pkey(data_dir='monitor-results/ib-pkey',
                 output_dir='monitor-results'):
    """Aggregate per-switch P_Key views, detect inconsistencies."""
    if not os.path.isdir(data_dir):
        print(f"No IB pkey data dir: {data_dir}")
        return
    
    per_device = {}     # hostname -> list of partition dicts
    pkey_seen = {}      # pkey -> {hostnames: set, names: set, mtus: set, rates: set, member_counts: list}
    
    for filename in sorted(os.listdir(data_dir)):
        if not filename.endswith('.txt'):
            continue
        hostname = filename[:-4]
        parts = parse_partitions(os.path.join(data_dir, filename))
        per_device[hostname] = parts
        
        for p in parts:
            pkey = p['pkey']
            if not pkey:
                continue
            entry = pkey_seen.setdefault(pkey, {
                'hostnames': set(),
                'names': set(),
                'mtus': set(),
                'rates': set(),
                'ipoib_states': set(),
                'member_counts': [],
            })
            entry['hostnames'].add(hostname)
            if p.get('name'):
                entry['names'].add(p['name'])
            if p.get('mtu'):
                entry['mtus'].add(p['mtu'])
            if p.get('rate'):
                entry['rates'].add(p['rate'])
            entry['ipoib_states'].add(bool(p.get('ipoib')))
            entry['member_counts'].append(len(p.get('members', [])))
    
    # Determine consistency: a P_Key is "consistent" if all devices reporting
    # it use the same name, MTU, rate, and IPoIB state.
    pkey_summary = []
    inconsistencies = []
    for pkey, info in sorted(pkey_seen.items()):
        consistent = (len(info['names']) <= 1 and
                       len(info['mtus']) <= 1 and
                       len(info['rates']) <= 1 and
                       len(info['ipoib_states']) <= 1)
        record = {
            'pkey': pkey,
            'names': sorted(info['names']),
            'devices': sorted(info['hostnames']),
            'device_count': len(info['hostnames']),
            'mtus': sorted(info['mtus']),
            'rates': sorted(info['rates']),
            'ipoib_states': sorted(map(str, info['ipoib_states'])),
            'max_members': max(info['member_counts']) if info['member_counts'] else 0,
            'consistent': consistent,
        }
        pkey_summary.append(record)
        if not consistent:
            inconsistencies.append(record)

    # Optional expected policy: expected_pkeys.yaml
    # This is a monitoring-only drift check, not configuration management.
    # Schema:
    # partitions:
    #   0x7fff:
    #     name: default
    #     required_on: all
    #     min_members: 1
    #   0x8001:
    #     name: ai-training
    #     required_on_roles: [leaf, spine]   # optional, currently advisory
    policy = {'enabled': False, 'violations': [], 'summary': {'expected': 0, 'pass': 0, 'warning': 0, 'missing': 0, 'unexpected': 0}}
    expected_path = os.path.join(os.path.dirname(output_dir), 'expected_pkeys.yaml')
    if yaml and os.path.exists(expected_path):
        try:
            with open(expected_path) as f:
                expected_cfg = yaml.safe_load(f) or {}
            expected = expected_cfg.get('partitions') or {}
            policy['enabled'] = True
            policy['expected_file'] = expected_path
            policy['summary']['expected'] = len(expected)
            seen_pkeys = set(pkey_seen.keys())
            expected_pkeys = {str(k).lower(): v for k, v in expected.items()}
            for epkey, spec in expected_pkeys.items():
                if epkey not in seen_pkeys:
                    policy['summary']['missing'] += 1
                    policy['violations'].append({'pkey': epkey, 'severity': 'critical', 'type': 'missing', 'message': 'Expected P_Key not present on any polled switch'})
                    continue
                rec = next((r for r in pkey_summary if r['pkey'] == epkey), None)
                notes = []
                min_members = spec.get('min_members') if isinstance(spec, dict) else None
                if min_members and rec and rec.get('max_members', 0) < int(min_members):
                    notes.append(f"member count {rec.get('max_members', 0)} < expected {min_members}")
                exp_name = spec.get('name') if isinstance(spec, dict) else None
                if exp_name and rec and rec.get('names') and exp_name not in rec.get('names', []):
                    notes.append(f"name mismatch: expected {exp_name}, saw {rec.get('names')}")
                if notes:
                    policy['summary']['warning'] += 1
                    policy['violations'].append({'pkey': epkey, 'severity': 'warning', 'type': 'drift', 'message': '; '.join(notes)})
                else:
                    policy['summary']['pass'] += 1
            for actual in sorted(seen_pkeys - set(expected_pkeys.keys())):
                policy['summary']['unexpected'] += 1
                policy['violations'].append({'pkey': actual, 'severity': 'info', 'type': 'unexpected', 'message': 'P_Key exists in fabric but is not listed in expected_pkeys.yaml'})
        except Exception as e:
            policy = {'enabled': True, 'error': str(e), 'violations': [], 'summary': {'expected': 0, 'pass': 0, 'warning': 0, 'missing': 0, 'unexpected': 0}}
    
    result = {
        'last_update': datetime.now().isoformat(),
        'pkeys': pkey_summary,
        'per_device': {
            host: [
                {'name': p['name'], 'pkey': p['pkey'], 'mtu': p['mtu'],
                 'rate': p['rate'], 'ipoib': p['ipoib'],
                 'member_count': len(p['members'])}
                for p in parts
            ]
            for host, parts in per_device.items()
        },
        'summary': {
            'total_pkeys': len(pkey_seen),
            'devices_polled': len(per_device),
            'inconsistencies': len(inconsistencies),
            'policy_violations': len(policy.get('violations', [])),
        }
    }
    result['policy'] = policy
    
    output_path = os.path.join(output_dir, 'ib_pkey.json')
    with open(output_path, 'w') as f:
        json.dump(result, f, indent=2)
    
    print(f"IB P_Key: {len(pkey_seen)} partitions across {len(per_device)} devices, "
          f"{len(inconsistencies)} inconsistencies")


if __name__ == '__main__':
    process_pkey()
