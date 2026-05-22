#!/usr/bin/env python3
"""Process hardware health data collected by ib-monitor.sh.

The ib-monitor.sh script writes per-switch IB_HARDWARE section output to
monitor-results/hardware-data/<host>_hardware.txt. This wrapper just makes
sure the directory exists and then defers to generate_hardware_html.py.

Copyright (c) 2024-2026 LLDPq Project
Licensed under MIT License - see LICENSE file for details
"""

import os
import sys
import subprocess
from datetime import datetime


def main():
    """Main function"""
    print("Starting hardware health data processing...")
    
    data_dir = "monitor-results"
    print(f"Data directory: {os.path.abspath(data_dir)}")
    
    if not os.path.exists(data_dir):
        print(f"❌ Data directory not found: {data_dir}")
        print("💡 Run ib-monitor.sh first to collect data")
        sys.exit(1)
    
    # Check for hardware data files  
    hardware_data_dir = f"{data_dir}/hardware-data"
    processed_count = 0
    
    if os.path.exists(hardware_data_dir):
        hardware_files = [f for f in os.listdir(hardware_data_dir) if f.endswith('_hardware.txt')]
        processed_count = len(hardware_files)
        if processed_count > 0:
            print(f"Found {processed_count} hardware data files")
        else:
            print("No hardware data files found to process")
    else:
        print("Hardware data directory doesn't exist yet.")
    
    # Always generate the BER-style HTML from existing hardware_history.json
    try:
        print("Generating BER-style hardware analysis HTML...")
        result = subprocess.run([sys.executable, "generate_hardware_html.py"], 
                              capture_output=True, text=True, cwd=".")
        if result.returncode == 0:
            print("BER-style hardware analysis HTML generated successfully!")
            print(result.stdout.strip())
        else:
            print(f"❌ Error generating HTML: {result.stderr}")
    except Exception as e:
        print(f"❌ Error running generate_hardware_html.py: {e}")
    
    print(f"[{datetime.now()}] Hardware data processing completed")
    
    if processed_count == 0:
        print("\n💡 No hardware data yet — run ib-monitor.sh once. The "
              "IB_HARDWARE marker section in ib-monitor.sh populates the "
              "hardware-data/ directory consumed here.")


if __name__ == "__main__":
    main()