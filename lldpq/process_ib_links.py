#!/usr/bin/env python3
"""
Process IB link error data collected by ib-monitor.sh

Parses 'ib ibqueryerrors --details' or 'ib perfquery -a' output from each
switch and feeds counters into IbLinkAnalyzer. Output is ib_link_errors.json
consumed by the web UI.

Copyright (c) 2024-2026 LLDPq Project
Licensed under MIT License - see LICENSE file for details
"""

import os
import re
import json
from datetime import datetime
from ib_link_analyzer import IbLinkAnalyzer, TRACKED_COUNTERS


# ibqueryerrors --details output (per port):
#   GUID 0x...
#   Performance: PortXmitDiscards 5
#                LinkDownedCounter 2
#                SymbolErrorCounter 145
#   ...
#
# perfquery -a output (one block per port):
#   # Port counters: Lid 1 port 1
#   PortXmitData: ......
#   LinkDownedCounter: 2
#   ...

_COUNTER_RE = re.compile(r'^[\s\t]*(\w+):?[\s]+(\d+)')
# Match dedicated port header lines like "port 1:" or "# Port counters: Lid 5 port 3"
_PORT_HEADER_RE = re.compile(r'^\s*(?:#\s*)?(?:port\s+counters[^:]*:\s*(?:lid\s+\d+\s+)?port\s+(\d+)|port\s+(\d+)\s*:)', re.IGNORECASE)
_GUID_RE = re.compile(r'(?:GUID|guid|switchguid)[\s:]*?(0x[0-9a-fA-F]+)', re.IGNORECASE)


def parse_perfquery(filepath):
    """Parse perfquery / ibqueryerrors output into per-port counter dicts.
    
    Returns: dict of port_id -> {counter_name: int_value}
    
    port_id is "GUID:port_num" if GUID is present, else "port:N"
    """
    if not os.path.exists(filepath):
        return {}
    
    result = {}
    current_guid = None
    current_port = None
    
    try:
        with open(filepath, 'r') as f:
            for line in f:
                line = line.rstrip()
                if not line:
                    continue
                
                # Update current GUID on any line containing one (e.g. "GUID 0x...")
                guid_match = _GUID_RE.search(line)
                if guid_match:
                    current_guid = guid_match.group(1).lower()
                
                # Update current port on a port header line
                port_match = _PORT_HEADER_RE.match(line)
                if port_match:
                    p = port_match.group(1) or port_match.group(2)
                    if p:
                        current_port = int(p)
                        continue
                
                # Counter line
                m = _COUNTER_RE.match(line)
                if not m:
                    continue
                key, val = m.group(1), m.group(2)
                if key not in TRACKED_COUNTERS:
                    continue
                
                # Build port id (need either GUID+port or just port)
                if current_guid and current_port is not None:
                    port_id = f"{current_guid}:{current_port}"
                elif current_port is not None:
                    port_id = f"port{current_port}"
                else:
                    continue
                
                result.setdefault(port_id, {})[key] = int(val)
    except Exception:
        pass
    
    return result


def process_links(data_dir='monitor-results/ib-perfquery',
                  output_dir='monitor-results'):
    """Aggregate per-switch perfquery data and detect anomalies."""
    if not os.path.isdir(data_dir):
        print(f"No IB perfquery data dir: {data_dir}")
        return
    
    analyzer = IbLinkAnalyzer(data_dir=output_dir)
    
    total_ports = 0
    for filename in sorted(os.listdir(data_dir)):
        if not filename.endswith('.txt'):
            continue
        hostname = filename[:-4]
        filepath = os.path.join(data_dir, filename)
        
        port_counters = parse_perfquery(filepath)
        for port_id, counters in port_counters.items():
            analyzer.update(hostname, port_id, counters)
            total_ports += 1
    
    # Top problem ports
    problems = analyzer.top_problem_ports(limit=50)
    
    # Persist history for next cycle
    analyzer.save_history()
    
    result = {
        'last_update': datetime.now().isoformat(),
        'total_ports_monitored': total_ports,
        'problem_ports': problems,
        'summary': {
            'critical_count': sum(1 for p in problems if p['severity'] == 'critical'),
            'warning_count': sum(1 for p in problems if p['severity'] == 'warning'),
            'flapping_1h': sum(1 for p in problems if p.get('flaps_1h', 0) > 0),
        }
    }
    
    output_path = os.path.join(output_dir, 'ib_link_errors.json')
    with open(output_path, 'w') as f:
        json.dump(result, f, indent=2)
    
    print(f"IB link errors: {total_ports} ports, "
          f"{result['summary']['critical_count']} critical, "
          f"{result['summary']['warning_count']} warning, "
          f"{result['summary']['flapping_1h']} flapping (1h)")


if __name__ == '__main__':
    process_links()
