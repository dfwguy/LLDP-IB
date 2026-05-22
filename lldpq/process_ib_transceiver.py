#!/usr/bin/env python3
"""
Process IB transceiver inventory data collected by ib-monitor.sh

Parses MLNX-OS 'show interfaces ib transceiver' (vendor info) and
'show interfaces ib transceiver diagnostics' (RX/TX power, FW version)
to build a fabric-wide transceiver inventory.

Output: monitor-results/transceiver_inventory.json (same schema as the
Ethernet edition so the existing transceiver.html UI works unchanged).

Copyright (c) 2024-2026 LLDPq Project
Licensed under MIT License - see LICENSE file for details
"""

import os
import re
import json
from datetime import datetime


# MLNX-OS 'show interfaces ib X/Y transceiver' output format:
#
#   Slot 1 port 36 state
#           identifier             : QSFP+
#           cable/module type      : Passive copper, unequalized
#           infiniband speeds      : SDR , DDR , QDR , FDR, HDR, NDR
#           vendor                 : Mellanox
#           cable length           : 2m
#           part number            : MC2207130-0A1
#           revision               : A3
#           serial number          : MT1324VS02215
#
# 'show interfaces ib X/Y transceiver diagnostics' adds:
#           firmware version       : 79.151.0
#           temperature [C]        : 42
#           rx power [dBm]         : -1.23, -1.18, -1.20, -1.19
#           tx power [dBm]         : 2.54, 2.53, 2.51, 2.52


_PORT_HEADER_RE = re.compile(r'Slot\s+(\d+)\s+port\s+(\d+(?:/\d+)?)\s+state', re.IGNORECASE)
_FIELD_RE = re.compile(r'^\s*([A-Za-z][A-Za-z _\-\[\]/0-9]+?)\s*:\s*(.+?)\s*$')


def parse_ib_transceiver(filepath):
    """Parse 'show interfaces ib transceiver [diagnostics]' output.
    
    Returns: dict of port_name -> {identifier, vendor, part_number, serial,
                                    vendor_rev, fw_version, ...}
    """
    if not os.path.exists(filepath):
        return {}
    
    result = {}
    current_port = None
    
    try:
        with open(filepath, 'r') as f:
            for line in f:
                # Detect new port section
                hdr = _PORT_HEADER_RE.search(line)
                if hdr:
                    slot, port = hdr.group(1), hdr.group(2)
                    current_port = f"IB{slot}/{port}"
                    result[current_port] = {
                        'identifier': '',
                        'vendor': '',
                        'part_number': '',
                        'serial': '',
                        'vendor_rev': '',
                        'connector': '',
                        'fw_version': '',
                    }
                    continue
                
                if not current_port:
                    continue
                
                fld = _FIELD_RE.match(line)
                if not fld:
                    continue
                key = fld.group(1).strip().lower()
                val = fld.group(2).strip()
                
                if key == 'identifier':
                    result[current_port]['identifier'] = val
                elif key == 'vendor':
                    result[current_port]['vendor'] = val
                elif key == 'part number':
                    result[current_port]['part_number'] = val
                elif key in ('serial number', 'vendor sn'):
                    result[current_port]['serial'] = val
                elif key in ('revision', 'rev'):
                    result[current_port]['vendor_rev'] = val
                elif key in ('cable/module type', 'connector'):
                    result[current_port]['connector'] = val
                elif key in ('firmware version', 'fw version'):
                    # IB modules may report "N/A" for passive copper -- drop those
                    if val.upper() != 'N/A':
                        result[current_port]['fw_version'] = val
    except Exception:
        pass
    
    return result


def process_transceiver_data(transceiver_dir='monitor-results/ib-transceiver',
                              diagnostics_dir='monitor-results/optical-data',
                              output_dir='monitor-results'):
    """Build fabric-wide transceiver inventory JSON."""
    all_modules = []
    
    if not os.path.isdir(transceiver_dir):
        print(f"No IB transceiver data dir: {transceiver_dir}")
        return
    
    for filename in sorted(os.listdir(transceiver_dir)):
        if not filename.endswith('.txt'):
            continue
        hostname = filename[:-4]
        
        vendor_path = os.path.join(transceiver_dir, filename)
        diag_path = os.path.join(diagnostics_dir, f'{hostname}_optical.txt')
        
        # Parse vendor info from non-diagnostics output
        vendor_info = parse_ib_transceiver(vendor_path)
        
        # Parse FW + power from diagnostics output (same parser handles both)
        diag_info = parse_ib_transceiver(diag_path) if os.path.exists(diag_path) else {}
        
        # Merge: diagnostics output may have fw_version and power; vendor has the rest
        for port, info in vendor_info.items():
            diag = diag_info.get(port, {})
            if diag.get('fw_version'):
                info['fw_version'] = diag['fw_version']
            
            all_modules.append({
                'device': hostname,
                'port': port,
                'identifier': info['identifier'],
                'vendor': info['vendor'],
                'part_number': info['part_number'],
                'serial': info['serial'],
                'vendor_rev': info['vendor_rev'],
                'connector': info['connector'],
                'fw_version': info['fw_version'],
                'fw_status': 'ok' if info['fw_version'] else 'no_data',
                'fw_status_detail': '',
            })
    
    # Build summary (same shape as Ethernet edition)
    unique_models = set()
    devices_with_modules = set()
    fw_by_model = {}
    status_counts = {}
    
    for m in all_modules:
        pn = m['part_number']
        if pn:
            unique_models.add(pn)
            devices_with_modules.add(m['device'])
            if m['fw_version']:
                fw_by_model.setdefault(pn, {})
                fw_by_model[pn][m['fw_version']] = fw_by_model[pn].get(m['fw_version'], 0) + 1
        status_counts[m['fw_status']] = status_counts.get(m['fw_status'], 0) + 1
    
    mixed_fw_models = [pn for pn, versions in fw_by_model.items() if len(versions) > 1]
    
    result = {
        'last_update': datetime.now().isoformat(),
        'modules': all_modules,
        'summary': {
            'total_modules': len(all_modules),
            'unique_models': len(unique_models),
            'devices_with_modules': len(devices_with_modules),
            'fw_versions': fw_by_model,
            'mixed_fw_models': mixed_fw_models,
            'status_counts': status_counts,
        }
    }
    
    output_path = os.path.join(output_dir, 'transceiver_inventory.json')
    with open(output_path, 'w') as f:
        json.dump(result, f, indent=2)
    
    print(f"IB transceiver inventory: {len(all_modules)} modules across "
          f"{len(devices_with_modules)} devices, {len(unique_models)} unique models"
          f"{f', {len(mixed_fw_models)} with mixed FW' if mixed_fw_models else ''}")


if __name__ == '__main__':
    process_transceiver_data()
