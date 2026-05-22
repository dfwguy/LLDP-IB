#!/usr/bin/env python3
"""
Process IB topology data collected by ib-monitor.sh

Parses 'ibnetdiscover -p' output from each switch and builds a fabric-wide
topology JSON: nodes (switches, HCAs), links (GUID + port mapping).

Copyright (c) 2024-2026 LLDPq Project
Licensed under MIT License - see LICENSE file for details
"""

import os
import re
import json
from datetime import datetime


# ibnetdiscover -p output format:
#   Ca   1 1 0x..guid.. 0x..port_guid.. 4xHDR  - SW   2 33 0x..switch_guid..  ( 'qm-spine01 IB' - 'host01 mlx5_0' )
#   SW   1 1 0x..switch_guid.. 0x..port_guid.. 4xHDR  - SW   2 5 0x..other_switch.. ( ... )
#
# Columns are space-separated; trailing ( '<local-desc>' - '<remote-desc>' ) is human-readable.

_LINE_RE = re.compile(
    r'^(?P<ltype>CA|SW|RT)\s+'
    r'(?P<llid>\d+)\s+'
    r'(?P<lport>\d+)\s+'
    r'(?P<lguid>0x[0-9a-fA-F]+)\s+'
    r'(?P<lportguid>0x[0-9a-fA-F]+)\s+'
    r'(?P<speed>\S+)\s+'
    r'-\s+'
    r'(?P<rtype>CA|SW|RT)\s+'
    r'(?P<rlid>\d+)\s+'
    r'(?P<rport>\d+)\s+'
    r'(?P<rguid>0x[0-9a-fA-F]+)'
    r'(?:.*?\(\s*\'(?P<ldesc>[^\']*)\'\s*-\s*\'(?P<rdesc>[^\']*)\'\s*\))?'
)


def parse_ibnetdiscover(filepath, source_hostname=''):
    """Parse a single switch's ibnetdiscover -p output. Returns list of link dicts."""
    links = []
    nodes = {}  # guid -> {type, desc, lid}
    
    if not os.path.exists(filepath):
        return links, nodes
    
    try:
        with open(filepath, 'r') as f:
            for line in f:
                m = _LINE_RE.match(line)
                if not m:
                    continue
                g = m.groupdict()
                
                # Normalize types: CA = Channel Adapter (HCA), SW = Switch, RT = Router
                type_map = {'CA': 'hca', 'SW': 'switch', 'RT': 'router'}
                
                local_guid = g['lguid'].lower()
                remote_guid = g['rguid'].lower()
                
                # Register both endpoints in node map
                nodes.setdefault(local_guid, {
                    'type': type_map[g['ltype']],
                    'description': g.get('ldesc') or '',
                    'lid': int(g['llid'])
                })
                nodes.setdefault(remote_guid, {
                    'type': type_map[g['rtype']],
                    'description': g.get('rdesc') or '',
                    'lid': int(g['rlid'])
                })
                
                links.append({
                    'source_guid': local_guid,
                    'source_port': int(g['lport']),
                    'source_type': type_map[g['ltype']],
                    'source_desc': g.get('ldesc') or '',
                    'target_guid': remote_guid,
                    'target_port': int(g['rport']),
                    'target_type': type_map[g['rtype']],
                    'target_desc': g.get('rdesc') or '',
                    'speed': g['speed'],
                    'discovered_from': source_hostname,
                })
    except Exception:
        pass
    
    return links, nodes


def merge_link(existing, candidate):
    """Merge two link records for the same physical link discovered from both ends."""
    # Prefer non-empty descriptions and accumulate discovery sources
    if not existing.get('source_desc') and candidate.get('source_desc'):
        existing['source_desc'] = candidate['source_desc']
    if not existing.get('target_desc') and candidate.get('target_desc'):
        existing['target_desc'] = candidate['target_desc']
    sources = set(s for s in (existing.get('discovered_from', '').split(',') + [candidate.get('discovered_from', '')]) if s)
    existing['discovered_from'] = ','.join(sorted(sources))


def link_key(link):
    """Canonical key for a link (order-independent)."""
    a = (link['source_guid'], link['source_port'])
    b = (link['target_guid'], link['target_port'])
    return tuple(sorted([a, b]))


def process_topology(data_dir='monitor-results/ib-topology',
                     output_dir='monitor-results'):
    """Aggregate per-switch ibnetdiscover output into a fabric-wide topology JSON."""
    all_links = {}
    all_nodes = {}
    
    if not os.path.isdir(data_dir):
        print(f"No IB topology data dir: {data_dir}")
        return
    
    for filename in sorted(os.listdir(data_dir)):
        if not filename.endswith('.txt'):
            continue
        hostname = filename[:-4]
        filepath = os.path.join(data_dir, filename)
        
        links, nodes = parse_ibnetdiscover(filepath, source_hostname=hostname)
        
        for link in links:
            key = link_key(link)
            if key in all_links:
                merge_link(all_links[key], link)
            else:
                all_links[key] = link
        
        for guid, info in nodes.items():
            if guid not in all_nodes:
                all_nodes[guid] = info
            else:
                # Prefer description from a node's own LLDPq monitor (most authoritative)
                if not all_nodes[guid].get('description') and info.get('description'):
                    all_nodes[guid]['description'] = info['description']
    
    # Build summary
    node_count_by_type = {'switch': 0, 'hca': 0, 'router': 0}
    for info in all_nodes.values():
        t = info.get('type', 'unknown')
        node_count_by_type[t] = node_count_by_type.get(t, 0) + 1
    
    speed_counts = {}
    for link in all_links.values():
        s = link.get('speed', 'unknown')
        speed_counts[s] = speed_counts.get(s, 0) + 1
    
    result = {
        'last_update': datetime.now().isoformat(),
        'nodes': [{'guid': g, **info} for g, info in all_nodes.items()],
        'links': list(all_links.values()),
        'summary': {
            'total_nodes': len(all_nodes),
            'total_links': len(all_links),
            'switches': node_count_by_type.get('switch', 0),
            'hcas': node_count_by_type.get('hca', 0),
            'routers': node_count_by_type.get('router', 0),
            'speed_distribution': speed_counts,
        }
    }
    
    output_path = os.path.join(output_dir, 'ib_topology.json')
    with open(output_path, 'w') as f:
        json.dump(result, f, indent=2)
    
    print(f"IB topology: {len(all_nodes)} nodes "
          f"({node_count_by_type.get('switch', 0)} switches, "
          f"{node_count_by_type.get('hca', 0)} HCAs), "
          f"{len(all_links)} links")


if __name__ == '__main__':
    process_topology()
