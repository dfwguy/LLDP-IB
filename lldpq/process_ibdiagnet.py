#!/usr/bin/env python3
"""
process_ibdiagnet.py - Parse an ibdiagnet output directory into a compact JSON summary.

This is the "parse" half of the parse-then-discard pipeline. ibdiagnet produces
2-3 GB of raw output (db_csv, pm per-lane, fdbs, ...); the *value* is the signal
inside it, not the bulk. We extract that signal into a few-KB JSON and let the
caller (run-ibdiagnet.sh) discard the raw files according to a retention policy.

Designed to be tolerant: ibdiagnet log/format varies between versions, so every
section is best-effort and missing data degrades to empty/null rather than error.

Usage:
    process_ibdiagnet.py <input_dir> <output_json>

Environment (optional metadata baked into the summary):
    IBDIAG_TARGET    target host the run was executed on
    IBDIAG_COMMAND   the exact command line that produced the output
    IBDIAG_STARTED   ISO timestamp the run started
    IBDIAG_FINISHED  ISO timestamp the run finished
    IBDIAG_RAW_ARCHIVE  filename of the retained raw archive (if any)
    IBDIAG_RAW_SIZE  size in bytes of the raw archive (if any)
    IBDIAG_RUN_ID    run identifier

Copyright (c) 2024-2026 LLDPq Project - Licensed under MIT License
"""
import json
import os
import re
import sys
from datetime import datetime, timezone

MAX_LINES = 80          # cap on stored error/warning lines (keep JSON small)
LINE_CLIP = 400         # max chars per stored line


def _read_text(path, limit_bytes=8 * 1024 * 1024):
    """Read a text file, tolerant of binary junk and size. Returns '' on failure."""
    try:
        with open(path, 'r', errors='replace') as f:
            return f.read(limit_bytes)
    except Exception:
        return ''


def _find_log(input_dir):
    """Locate the main ibdiagnet log file (name varies a little by version)."""
    candidates = ['ibdiagnet2.log', 'ibdiagnet.log']
    for name in candidates:
        p = os.path.join(input_dir, name)
        if os.path.isfile(p):
            return p
    # fall back to any *.log
    try:
        for name in sorted(os.listdir(input_dir)):
            if name.endswith('.log'):
                return os.path.join(input_dir, name)
    except Exception:
        pass
    return None


def parse_log(log_text):
    """Extract stage summary table + raw -E-/-W- lines from the ibdiagnet log."""
    stages = []
    errors = []
    warnings = []

    # Per-line severity markers. ibdiagnet uses "-E-" / "-W-" / "-I-" prefixes.
    for raw in log_text.splitlines():
        line = raw.rstrip()
        if not line:
            continue
        if '-E-' in line and len(errors) < MAX_LINES:
            errors.append(line.strip()[:LINE_CLIP])
        elif '-W-' in line and len(warnings) < MAX_LINES:
            warnings.append(line.strip()[:LINE_CLIP])

    # Stage summary table. Typical shape:
    #   -I- Stage                          Warnings   Errors     Comment
    #   -I- Bad GUIDs/LIDs Check           0          0
    #   -I- Link Speed Check               0          0
    #   ...
    # We capture rows that end in two integers (warnings, errors).
    row_re = re.compile(r'^-I-\s+(?P<name>.+?)\s+(?P<w>\d+)\s+(?P<e>\d+)\s*(?P<comment>.*)$')
    in_table = False
    for raw in log_text.splitlines():
        line = raw.rstrip()
        low = line.lower()
        if 'warnings' in low and 'errors' in low and 'stage' in low:
            in_table = True
            continue
        if not in_table:
            continue
        m = row_re.match(line)
        if m:
            name = m.group('name').strip()
            if name.lower() == 'summary':
                # Summary row: totals; record and stop scanning the table.
                stages.append({
                    'name': 'Summary',
                    'warnings': int(m.group('w')),
                    'errors': int(m.group('e')),
                    'comment': m.group('comment').strip(),
                })
                in_table = False
            else:
                stages.append({
                    'name': name,
                    'warnings': int(m.group('w')),
                    'errors': int(m.group('e')),
                    'comment': m.group('comment').strip(),
                })
        elif line and not line.startswith('-I-'):
            # left the contiguous table block
            in_table = False

    # Totals: prefer the Summary row; otherwise sum stage rows; otherwise count lines.
    total_w = total_e = None
    for s in stages:
        if s['name'] == 'Summary':
            total_w, total_e = s['warnings'], s['errors']
            break
    if total_e is None and stages:
        total_w = sum(s['warnings'] for s in stages if s['name'] != 'Summary')
        total_e = sum(s['errors'] for s in stages if s['name'] != 'Summary')
    if total_e is None:
        total_w = len(warnings)
        total_e = len(errors)

    return {
        'stages': [s for s in stages if s['name'] != 'Summary'],
        'totals': {'errors': total_e, 'warnings': total_w},
        'top_errors': errors,
        'top_warnings': warnings,
    }


def parse_fabric_summary(log_text):
    """Capture the ibdiagnet 'Fabric Summary' block verbatim (node / switch / CA /
    link / speed counts) for the detailed report view. Best-effort + version
    tolerant -- missing block degrades to []."""
    out = []
    capturing = False
    for raw in log_text.splitlines():
        s = raw.rstrip()
        if not capturing:
            if 'fabric summary' in s.strip().lower():
                capturing = True
            continue
        stripped = s.strip()
        # Stop at the next dashed separator or the stage-summary table header.
        if (stripped and set(stripped) == {'-'} and len(stripped) >= 6) \
                or stripped.lower().startswith('-i- stage'):
            break
        out.append(stripped[:LINE_CLIP])
        if len(out) >= 120:
            break
    while out and not out[-1]:
        out.pop()
    return out


def parse_header(log_text):
    """Pull the ibdiagnet version + run host from the log header."""
    info = {}
    m = re.search(r'Running version:\s*"?([^",\n]+)', log_text)
    if m:
        info['version'] = m.group(1).strip()
    m = re.search(r'Running on host:\s*(\S+)', log_text)
    if m:
        info['run_host'] = m.group(1).strip()
    return info


def parse_cables(input_dir):
    """Best-effort cable count from ibdiagnet2.cables / db_csv CABLE_INFO section."""
    cables_path = os.path.join(input_dir, 'ibdiagnet2.cables')
    count = 0
    if os.path.isfile(cables_path):
        text = _read_text(cables_path, limit_bytes=4 * 1024 * 1024)
        # Each cable block usually starts with a "Port=" or "PN" header line.
        for line in text.splitlines():
            if re.search(r'\bPN\b|\bVendor\b|Port=', line):
                count += 1
        return {'source': 'ibdiagnet2.cables', 'entries': count}

    # Fall back to the CABLE_INFO table inside the db_csv (if present and not huge).
    db_path = os.path.join(input_dir, 'ibdiagnet2.db_csv')
    if os.path.isfile(db_path) and os.path.getsize(db_path) < 32 * 1024 * 1024:
        text = _read_text(db_path)
        m = re.search(r'START_CABLE_INFO(.*?)END_CABLE_INFO', text, re.DOTALL)
        if m:
            rows = [r for r in m.group(1).splitlines() if r.strip()]
            # first row is the CSV header
            count = max(0, len(rows) - 1)
            return {'source': 'db_csv', 'entries': count}
    return {'source': None, 'entries': 0}


def list_output_files(input_dir):
    """List output files + sizes so the UI can show what the raw run contained."""
    files = []
    try:
        for name in sorted(os.listdir(input_dir)):
            p = os.path.join(input_dir, name)
            if os.path.isfile(p):
                files.append({'name': name, 'size_bytes': os.path.getsize(p)})
    except Exception:
        pass
    return files


def main():
    if len(sys.argv) < 3:
        sys.stderr.write('usage: process_ibdiagnet.py <input_dir> <output_json>\n')
        return 2

    input_dir = sys.argv[1]
    output_json = sys.argv[2]

    summary = {
        'generated_at': datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC'),
        'run_id': os.environ.get('IBDIAG_RUN_ID', ''),
        'target': os.environ.get('IBDIAG_TARGET', ''),
        'command': os.environ.get('IBDIAG_COMMAND', ''),
        'started_at': os.environ.get('IBDIAG_STARTED', ''),
        'finished_at': os.environ.get('IBDIAG_FINISHED', ''),
        'raw_archive': os.environ.get('IBDIAG_RAW_ARCHIVE', ''),
        'raw_size_bytes': int(os.environ.get('IBDIAG_RAW_SIZE', '0') or 0),
        'totals': {'errors': None, 'warnings': None},
        'stages': [],
        'top_errors': [],
        'top_warnings': [],
        'fabric_summary': [],
        'cables': {'source': None, 'entries': 0},
        'files': [],
        'parsed': False,
    }

    if not os.path.isdir(input_dir):
        summary['error'] = f'Input dir not found: {input_dir}'
    else:
        log_path = _find_log(input_dir)
        if log_path:
            log_text = _read_text(log_path)
            parsed = parse_log(log_text)
            summary.update(parsed)
            summary['fabric_summary'] = parse_fabric_summary(log_text)
            summary.update(parse_header(log_text))
            summary['parsed'] = True
            summary['log_file'] = os.path.basename(log_path)
        else:
            summary['error'] = 'No ibdiagnet log file found in output'
        summary['cables'] = parse_cables(input_dir)
        summary['files'] = list_output_files(input_dir)

    try:
        with open(output_json, 'w') as f:
            json.dump(summary, f, indent=2)
    except Exception as e:
        sys.stderr.write(f'Cannot write {output_json}: {e}\n')
        return 1

    t = summary['totals']
    print(f"ibdiagnet parsed: errors={t['errors']} warnings={t['warnings']} "
          f"stages={len(summary['stages'])} cables={summary['cables']['entries']}")
    return 0


if __name__ == '__main__':
    sys.exit(main())
