#!/usr/bin/env bash
# run-ibdiagnet.sh - Run a full-fabric ibdiagnet on a target, parse it, discard the raw.
#
# This is the "parse-then-discard" engine behind the Diagnostics page and the
# (opt-in) scheduled fabric diagnostic. ibdiagnet emits 2-3 GB of raw output; we
# pull back only the small files needed to parse, extract the signal into a tiny
# JSON, optionally retain ONE compressed archive for download, and delete the
# rest. A retention policy prunes old runs so the data volume never grows
# unbounded.
#
# NOTHING here runs from cron by default. Cron only invokes this when the admin
# explicitly sets IBDIAGNET_SCHEDULE (see docker-entrypoint.sh).
#
# Inputs (env):
#   IBDIAG_TARGET     host/IP to SSH into and run ibdiagnet (required unless mock)
#   IBDIAG_USER       SSH user (default: admin; UFM appliance often 'root')
#   IBDIAG_BIN        ibdiagnet binary path (default: ibdiagnet;
#                     UFM appliance: /opt/ufm/opensm/bin/ibdiagnet)
#   IBDIAG_FLAGS      pre-validated ibdiagnet flag string (NO -o, no shell metachars)
#   IBDIAG_RUN_ID     run identifier (default: generated timestamp)
#   IBDIAGNET_KEEP_RAW   number of raw archives to retain (default: 1; 0 = leanest)
#   IBDIAGNET_KEEP_RUNS  number of parsed run summaries to retain (default: 20)
#   LLDPQ_IB_MOCK=1   use a fixture dir instead of SSH (for tests/demo)
#
# Copyright (c) 2024-2026 LLDPq Project - Licensed under MIT License

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source /etc/lldpq.conf 2>/dev/null || true
WEB_ROOT="${WEB_ROOT:-/var/www/html}"
LLDPQ_USER="${LLDPQ_USER:-${USER:-lldpq}}"

MOCK_MODE="${LLDPQ_IB_MOCK:-0}"
MOCK_DIR="${LLDPQ_IB_MOCK_DIR:-$SCRIPT_DIR/../tests/fixtures/ibdiagnet}"

KEEP_RAW="${IBDIAGNET_KEEP_RAW:-1}"
KEEP_RUNS="${IBDIAGNET_KEEP_RUNS:-20}"
case "$KEEP_RAW"  in ''|*[!0-9]*) KEEP_RAW=1 ;; esac
case "$KEEP_RUNS" in ''|*[!0-9]*) KEEP_RUNS=20 ;; esac

TARGET="${IBDIAG_TARGET:-}"
SSH_USER="${IBDIAG_USER:-admin}"
BIN="${IBDIAG_BIN:-ibdiagnet}"
FLAGS="${IBDIAG_FLAGS:-}"
RUN_ID="${IBDIAG_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"

RESULTS_DIR="$SCRIPT_DIR/monitor-results"
RUNS_DIR="$RESULTS_DIR/ibdiag-runs"
mkdir -p "$RUNS_DIR"

STATUS_FILE="$RUNS_DIR/${RUN_ID}.status"
RUN_JSON="$RUNS_DIR/${RUN_ID}.json"
RAW_ARCHIVE="$RUNS_DIR/${RUN_ID}.tar.gz"
RUN_LOG="$RUNS_DIR/${RUN_ID}.run.log"
LATEST_JSON="$RESULTS_DIR/ib_fabric_diag.json"
INDEX_JSON="$RUNS_DIR/index.json"

STARTED_AT=$(date -u '+%Y-%m-%d %H:%M:%S UTC')

# ---------------------------------------------------------------------------
# status helper: write a small JSON status file the UI polls.
# ---------------------------------------------------------------------------
set_status() {
    local state="$1"; local message="$2"
    RUN_ID="$RUN_ID" STATE="$state" MSG="$message" TARGET="$TARGET" \
    STARTED="$STARTED_AT" python3 - "$STATUS_FILE" <<'PY' 2>/dev/null || true
import json, os, sys
from datetime import datetime, timezone
out = sys.argv[1]
json.dump({
    'run_id':  os.environ.get('RUN_ID', ''),
    'state':   os.environ.get('STATE', ''),
    'message': os.environ.get('MSG', ''),
    'target':  os.environ.get('TARGET', ''),
    'started_at': os.environ.get('STARTED', ''),
    'updated_at': datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC'),
}, open(out, 'w'))
PY
    chown "$LLDPQ_USER:www-data" "$STATUS_FILE" 2>/dev/null || true
    chmod 664 "$STATUS_FILE" 2>/dev/null || true
}

fail() {
    set_status "error" "$1"
    echo "ERROR: $1" >> "$RUN_LOG" 2>/dev/null || true
    publish
    exit 1
}

# Copy run artefacts to the web root so the UI (www-data) can read them.
publish() {
    mkdir -p "$WEB_ROOT/monitor-results/ibdiag-runs" 2>/dev/null || true
    cp -f "$STATUS_FILE" "$WEB_ROOT/monitor-results/ibdiag-runs/" 2>/dev/null || true
    [ -f "$RUN_JSON" ]     && cp -f "$RUN_JSON"     "$WEB_ROOT/monitor-results/ibdiag-runs/" 2>/dev/null || true
    [ -f "$RAW_ARCHIVE" ]  && cp -f "$RAW_ARCHIVE"  "$WEB_ROOT/monitor-results/ibdiag-runs/" 2>/dev/null || true
    [ -f "$INDEX_JSON" ]   && cp -f "$INDEX_JSON"   "$WEB_ROOT/monitor-results/ibdiag-runs/" 2>/dev/null || true
    [ -f "$LATEST_JSON" ]  && cp -f "$LATEST_JSON"  "$WEB_ROOT/monitor-results/" 2>/dev/null || true
    chown -R "$LLDPQ_USER:www-data" "$WEB_ROOT/monitor-results/ibdiag-runs" 2>/dev/null || true
    chmod -R ug+rw "$WEB_ROOT/monitor-results/ibdiag-runs" 2>/dev/null || true
}

echo "=== ibdiagnet run $RUN_ID @ $STARTED_AT ===" > "$RUN_LOG"
set_status "running" "Starting ibdiagnet on ${TARGET:-mock}"
publish

# ---------------------------------------------------------------------------
# Validate flags (defense in depth -- diag-api.sh already builds them safely).
# Allow only the safe ibdiagnet flag character set; never pass shell metachars.
# ---------------------------------------------------------------------------
if [ -n "$FLAGS" ] && printf '%s' "$FLAGS" | grep -q '[^A-Za-z0-9 _,=./-]'; then
    fail "Refusing unsafe ibdiagnet flags"
fi
# We always control -o ourselves; reject if a caller smuggled one in.
case " $FLAGS " in *" -o "*) fail "Flags must not include -o (output path is managed)" ;; esac

PARSE_DIR=$(mktemp -d /tmp/lldpq-ibdiag-parse.XXXXXX)
trap 'rm -rf "$PARSE_DIR" 2>/dev/null || true' EXIT

# ---------------------------------------------------------------------------
# MOCK mode: copy the fixture output dir and parse it. No SSH, no transfer.
# ---------------------------------------------------------------------------
if [ "$MOCK_MODE" = "1" ]; then
    echo "MOCK mode: using fixture $MOCK_DIR" >> "$RUN_LOG"
    if [ ! -d "$MOCK_DIR" ]; then
        fail "Mock fixture dir not found: $MOCK_DIR"
    fi
    set_status "parsing" "Parsing fixture output"
    cp -rf "$MOCK_DIR/." "$PARSE_DIR/" 2>/dev/null || true
    if [ "$KEEP_RAW" -gt 0 ]; then
        tar czf "$RAW_ARCHIVE" -C "$PARSE_DIR" . 2>/dev/null || true
    fi
    CMD_LINE="$BIN $FLAGS -o <out>   (MOCK fixture)"
else
    # -----------------------------------------------------------------------
    # Real mode: SSH to target, run ibdiagnet into a remote temp dir.
    # -----------------------------------------------------------------------
    if [ -z "$TARGET" ]; then
        fail "IBDIAG_TARGET is required (no mock mode)"
    fi
    if ! printf '%s' "$TARGET" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$|^[0-9.]+$|^[0-9a-fA-F:]+$'; then
        fail "Invalid target host"
    fi

    REMOTE_TMP="/tmp/lldpq-ibdiag-${RUN_ID}"
    CMD_LINE="$BIN $FLAGS -o $REMOTE_TMP"
    # Use lldpq's SSH key. If we're already running as lldpq (cron), ssh directly;
    # if launched by the web (www-data via fcgiwrap), sudo to lldpq first.
    if [ "$(id -un 2>/dev/null)" = "$LLDPQ_USER" ]; then
        SSH=(ssh)
    else
        SSH=(sudo -u "$LLDPQ_USER" ssh)
    fi
    SSH+=(-o BatchMode=yes -o StrictHostKeyChecking=no
          -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=12)

    set_status "running" "Running ibdiagnet on $TARGET (this can take minutes)"
    echo "\$ $CMD_LINE" >> "$RUN_LOG"
    if ! "${SSH[@]}" "$SSH_USER@$TARGET" \
            "mkdir -p '$REMOTE_TMP' && $BIN $FLAGS -o '$REMOTE_TMP'" \
            >> "$RUN_LOG" 2>&1; then
        # ibdiagnet returns non-zero when it finds fabric errors; that is still a
        # valid, parseable run. Only bail if no output dir was produced.
        echo "(ibdiagnet exited non-zero -- continuing to collect output)" >> "$RUN_LOG"
    fi

    set_status "collecting" "Collecting + pruning raw output from $TARGET"
    # Parse-pull: everything EXCEPT the known-huge files (keeps transfer tiny).
    "${SSH[@]}" "$SSH_USER@$TARGET" \
        "tar czf - -C '$REMOTE_TMP' --exclude=ibdiagnet2.db_csv --exclude=ibdiagnet2.pm --exclude='*.fdbs' --exclude='*.net_dump' . 2>/dev/null" \
        2>>"$RUN_LOG" | tar xzf - -C "$PARSE_DIR" 2>>"$RUN_LOG" || true

    # Optional raw archive (the big transfer) -- only when retention asks for it.
    if [ "$KEEP_RAW" -gt 0 ]; then
        "${SSH[@]}" "$SSH_USER@$TARGET" "tar czf - -C '$REMOTE_TMP' . 2>/dev/null" \
            > "$RAW_ARCHIVE" 2>>"$RUN_LOG" || true
        [ -s "$RAW_ARCHIVE" ] || rm -f "$RAW_ARCHIVE"
    fi

    # Always delete the raw output on the target -- never leave 2-3 GB behind.
    "${SSH[@]}" "$SSH_USER@$TARGET" "rm -rf '$REMOTE_TMP'" >> "$RUN_LOG" 2>&1 || true
    set_status "parsing" "Parsing diagnostic output"
fi

# ---------------------------------------------------------------------------
# Parse the collected output into a compact JSON summary.
# ---------------------------------------------------------------------------
FINISHED_AT=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
RAW_SIZE=0
RAW_NAME=""
if [ -f "$RAW_ARCHIVE" ]; then
    RAW_SIZE=$(wc -c < "$RAW_ARCHIVE" 2>/dev/null | tr -d ' ')
    RAW_NAME="$(basename "$RAW_ARCHIVE")"
fi

IBDIAG_RUN_ID="$RUN_ID" IBDIAG_TARGET="${TARGET:-mock}" IBDIAG_COMMAND="$CMD_LINE" \
IBDIAG_STARTED="$STARTED_AT" IBDIAG_FINISHED="$FINISHED_AT" \
IBDIAG_RAW_ARCHIVE="$RAW_NAME" IBDIAG_RAW_SIZE="$RAW_SIZE" \
    python3 "$SCRIPT_DIR/process_ibdiagnet.py" "$PARSE_DIR" "$RUN_JSON" >> "$RUN_LOG" 2>&1 \
    || fail "Parser failed (see ${RUN_ID}.run.log)"

cp -f "$RUN_JSON" "$LATEST_JSON" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Update the runs index + apply retention (prune old summaries + raw archives).
# ---------------------------------------------------------------------------
KEEP_RAW="$KEEP_RAW" KEEP_RUNS="$KEEP_RUNS" python3 - "$RUNS_DIR" "$INDEX_JSON" "$RUN_JSON" <<'PY' >> "$RUN_LOG" 2>&1 || true
import json, os, sys
runs_dir, index_json, run_json = sys.argv[1], sys.argv[2], sys.argv[3]
keep_raw  = int(os.environ.get('KEEP_RAW', '1') or 1)
keep_runs = int(os.environ.get('KEEP_RUNS', '20') or 20)

try:
    summary = json.load(open(run_json))
except Exception:
    summary = {}

meta = {
    'run_id':      summary.get('run_id', ''),
    'target':      summary.get('target', ''),
    'started_at':  summary.get('started_at', ''),
    'finished_at': summary.get('finished_at', ''),
    'errors':      (summary.get('totals') or {}).get('errors'),
    'warnings':    (summary.get('totals') or {}).get('warnings'),
    'raw_archive': summary.get('raw_archive', ''),
    'raw_size_bytes': summary.get('raw_size_bytes', 0),
}

index = []
if os.path.exists(index_json):
    try:
        index = json.load(open(index_json)) or []
    except Exception:
        index = []
# replace any existing entry with the same run_id, then prepend
index = [e for e in index if e.get('run_id') != meta['run_id']]
index.insert(0, meta)

# Retention: keep newest keep_runs summaries; prune the rest (json + status + log + raw).
survivors = index[:keep_runs]
pruned = index[keep_runs:]
for e in pruned:
    rid = e.get('run_id') or ''
    for suffix in ('.json', '.status', '.run.log', '.tar.gz'):
        p = os.path.join(runs_dir, rid + suffix)
        try:
            if os.path.exists(p):
                os.remove(p)
        except Exception:
            pass

# Raw-archive retention: keep only the newest keep_raw archives among survivors.
raw_kept = 0
for e in survivors:
    rid = e.get('run_id') or ''
    arc = os.path.join(runs_dir, rid + '.tar.gz')
    if os.path.exists(arc):
        if raw_kept < keep_raw:
            raw_kept += 1
        else:
            try:
                os.remove(arc)
            except Exception:
                pass
            e['raw_archive'] = ''
            e['raw_size_bytes'] = 0

json.dump(survivors, open(index_json, 'w'), indent=2)
print(f"index updated: {len(survivors)} runs, raw archives kept={raw_kept}")
PY

set_status "done" "Diagnostic complete"
chown "$LLDPQ_USER:www-data" "$RUN_JSON" "$LATEST_JSON" "$INDEX_JSON" 2>/dev/null || true
chmod 664 "$RUN_JSON" "$LATEST_JSON" "$INDEX_JSON" 2>/dev/null || true
publish

echo "Done: $RUN_ID" >> "$RUN_LOG"
