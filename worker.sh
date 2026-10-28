#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  @file        worker.sh
#  @brief       Background queue worker: runs queued jobs ONE AT A TIME (FIFO).
#  @version     1.0.0
#
#  Job types:  url  -> download.sh (yt-dlp) then normalize.sh --file for each result
#              file -> normalize.sh --file (original kept for shared local files)
#  Safe to start any number of times: only one worker runs; the others exit.
#  If killed or the phone restarts, unfinished jobs resume on the next start.
#
#  Usage: worker.sh [-h]     (drains the queue, then exits)
#  Stop:  touch "$QUEUE_DIR/.stop"   (finishes the current job, then stops)
# ═══════════════════════════════════════════════════════════════════════════════
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUEUE_DIR="${QUEUE_DIR:-$SCRIPT_DIR/data/queue}"; export QUEUE_DIR
PY="${PYTHON:-python3}"
LOG="$SCRIPT_DIR/media_processor_log.txt"
LOG_MAX="${LOG_MAX_BYTES:-$(( 2 * 1024 * 1024 ))}"
LOCK="$QUEUE_DIR/.worker.lock"
SCAN_OWN=1; [[ -n "${MEDIA_SCAN_QUEUE:-}" ]] && SCAN_OWN=0   # caller (master_run) scans once at its end
SCANQ="${MEDIA_SCAN_QUEUE:-$QUEUE_DIR/.scan.pending}"      # saved-but-not-yet-scanned files (own queue survives a kill)

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0; fi

if [[ -t 1 ]]; then C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_RED='\033[0;31m'; C_BLUE='\033[0;34m'; C_RESET='\033[0m'
else C_GREEN='' C_YELLOW='' C_RED='' C_BLUE='' C_RESET=''; fi

log() { printf '[%s] [WORKER] %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }
qctl() { "$PY" "$SCRIPT_DIR/qctl.py" "$@"; }
trim_log() {
    local sz; sz=$(wc -c < "$LOG" 2>/dev/null || echo 0)
    (( sz > LOG_MAX )) && tail -c $(( LOG_MAX / 2 )) "$LOG" > "$LOG.tmp" && mv -f "$LOG.tmp" "$LOG"
    return 0
}
# shellcheck source=scan_lib.sh
source "$SCRIPT_DIR/scan_lib.sh"

for bin in "$PY" ffmpeg ffprobe awk; do
    command -v "$bin" &>/dev/null || { printf "${C_RED}[FATAL] '%s' not found in PATH${C_RESET}\n" "$bin" >&2; exit 1; }
done
mkdir -p "$QUEUE_DIR" 2>/dev/null
if [[ ! -d "$QUEUE_DIR" || ! -w "$QUEUE_DIR" ]]; then
    printf "${C_RED}[ERROR] Queue folder is not usable: %s (check with: q selftest)${C_RESET}\n" "$QUEUE_DIR" >&2
    exit 1
fi
: >> "$LOG"

# ── Single worker: atomic mkdir lock with PID; a dead owner's lock is taken over ──
acquire_lock() {
    local owner
    if mkdir "$LOCK" 2>/dev/null; then echo $$ > "$LOCK/pid"; return 0; fi
    owner=$(cat "$LOCK/pid" 2>/dev/null || true)
    if [[ -n "$owner" ]] && kill -0 "$owner" 2>/dev/null; then return 1; fi
    log "Stale worker lock (pid ${owner:-?}) removed"
    rm -rf "$LOCK"
    mkdir "$LOCK" 2>/dev/null && echo $$ > "$LOCK/pid"
}
release_lock() { [[ "$(cat "$LOCK/pid" 2>/dev/null)" == "$$" ]] && rm -rf "$LOCK"; return 0; }

if ! acquire_lock; then
    printf "${C_YELLOW}[!] A worker is already running. Jobs will be processed by it.${C_RESET}\n"
    exit 0
fi

CHILD=""; CUR_ID=""; WAKE=0
# keep the CPU awake while working (Termux only; harmless if missing)
wake_on()  { command -v termux-wake-lock &>/dev/null && termux-wake-lock 2>/dev/null && WAKE=1; return 0; }
wake_off() { (( WAKE )) && termux-wake-unlock 2>/dev/null; WAKE=0; return 0; }
on_signal() {
    [[ -n "$CHILD" ]] && kill "$CHILD" 2>/dev/null && wait "$CHILD" 2>/dev/null
    if [[ -n "$CUR_ID" ]]; then qctl requeue "$CUR_ID" >/dev/null 2>&1; log "Interrupted; job $CUR_ID put back in the queue"; fi
    (( SCAN_OWN )) && { scan_queue "$SCANQ"; rm -f "$SCANQ"; }
    wake_off; release_lock; exit 143
}
trap on_signal INT TERM HUP
trap "wake_off; release_lock" EXIT

run_child() { "$@" & CHILD=$!; wait "$CHILD"; local rc=$?; CHILD=""; return "$rc"; }

# normalize one file; sets JOB_OUT (OUTPUT line) and returns the normalize exit code
normalize_one() {   # normalize_one PATH KEEP(0/1)
    local f="$1" keep="$2" rf rc; local -a extra=()
    rf=$(mktemp "$QUEUE_DIR/.res.XXXXXX")
    [[ "$keep" == "1" ]] && extra=(--keep-original)
    NORMALIZE_RESULT_FILE="$rf" MEDIA_SCAN_QUEUE="$SCANQ" run_child bash "$SCRIPT_DIR/normalize.sh" --file "$f" "${extra[@]}"
    rc=$?
    JOB_OUT=$(sed -n 's/^OUTPUT=//p' "$rf" | head -1)
    rm -f "$rf"
    return "$rc"
}
explain() { case "$1" in 64) echo "invalid setting (check Settings / config.conf)";; 1) echo "processing failed (source kept)";; 2) echo "no video stream";; 3) echo "unsupported video (ByteVC2, no H.264 copy)";; *) echo "exit code $1";; esac; }

process_job() {   # process_job ID TYPE KEEP VALUE ARGS -> 0 = done, 1 = failed (message in JOB_ERR)
    local id="$1" type="$2" keep="$3" value="$4" rawargs="${5:-}" rc p outs="" errs="" n=0
    local -a paths=() dlargs=()
    [[ -n "$rawargs" ]] && IFS=$'\x1f' read -r -a dlargs <<< "$rawargs"
    JOB_OUT=""; JOB_ERR=""
    if [[ "$type" == "file" ]]; then
        [[ -f "$value" ]] || { JOB_ERR="file not found: $value"; return 1; }
        normalize_one "$value" "$keep"; rc=$?
        (( rc == 0 )) && { JOB_OUT="$JOB_OUT"; return 0; }
        JOB_ERR="$(explain "$rc")"; return 1
    fi
    # url
    local resf; resf=$(mktemp "$QUEUE_DIR/.res.XXXXXX")
    DL_RESULT_FILE="$resf" run_child bash "$SCRIPT_DIR/download.sh" "$value" "${dlargs[@]}"; rc=$?
    if (( rc != 0 )); then rm -f "$resf"; JOB_ERR="download failed (exit $rc)"; return 1; fi
    while IFS= read -r p; do [[ -n "$p" ]] && paths+=("$p"); done < "$resf"
    rm -f "$resf"
    (( ${#paths[@]} > 0 )) || { JOB_ERR="download reported no file"; return 1; }
    for p in "${paths[@]}"; do
        [[ -f "$p" ]] || { errs+="missing: $(basename "$p"); "; continue; }
        normalize_one "$p" 0; rc=$?
        if (( rc == 0 )); then outs+="${JOB_OUT};"; (( ++n )); else errs+="$(basename "$p"): $(explain "$rc"); "; fi
    done
    JOB_OUT="$outs"
    [[ -z "$errs" ]] && return 0
    JOB_ERR="${errs%; }"; return 1
}

# ── Main loop ─────────────────────────────────────────────────────────────────
trim_log
log "════════ Worker start (pid $$) ════════"
wake_on
rec=$(qctl recover 2>&1); rrc=$?
log "Recovery: $rec"
if (( rrc != 0 )); then
    printf "${C_RED}[ERROR] Queue unavailable: %s${C_RESET}\n" "$rec" >&2
    log "ERROR: queue unavailable at start: $rec"
    wake_off; exit 1
fi
(( SCAN_OWN )) && { scan_queue "$SCANQ"; rm -f "$SCANQ"; }   # outputs saved by an interrupted earlier run
rm -f "$QUEUE_DIR/.stop" "$QUEUE_DIR"/.res.* 2>/dev/null

ok=0; failed=0; QUEUE_ERR=0
while :; do
    stopped=0
    while :; do
        if [[ -f "$QUEUE_DIR/.stop" ]]; then rm -f "$QUEUE_DIR/.stop"; log "Stop requested"; printf "${C_YELLOW}[!] Stopped by request.${C_RESET}\n"; stopped=1; break; fi
        line=$(qctl next 2>&1); nrc=$?
        if (( nrc == 1 )); then break                                   # queue empty
        elif (( nrc != 0 )); then                                       # queue broken: say so, do not pretend we finished
            printf "${C_RED}[ERROR] Queue problem: %s${C_RESET}\n" "$line" >&2; log "ERROR: queue problem: $line"; QUEUE_ERR=1; break
        fi
        IFS=$'\t' read -r id type keep value jargs <<< "$line"
        CUR_ID="$id"
        printf "${C_BLUE}[job %s]${C_RESET} %s %s\n" "$id" "$type" "$value"
        log "Job $id start: $type $value"
        if process_job "$id" "$type" "$keep" "$value" "${jargs:-}"; then
            qctl done "$id" --output "$JOB_OUT" >/dev/null; (( ++ok )); log "Job $id DONE"
            printf "${C_GREEN}[job %s] done${C_RESET}\n" "$id"
        else
            qctl fail "$id" "$JOB_ERR" >/dev/null; (( ++failed )); log "Job $id FAILED: $JOB_ERR"
            printf "${C_RED}[job %s] failed: %s${C_RESET}\n" "$id" "$JOB_ERR" >&2
        fi
        CUR_ID=""
    done
    (( SCAN_OWN )) && { scan_queue "$SCANQ"; rm -f "$SCANQ"; }    # ONE media scan per drain, while we still hold the lock
    (( stopped )) && break
    # Close the race with a 'q add' that arrived while we were finishing:
    # let go of the lock, look once more, and take it back if work appeared.
    release_lock
    st=$(qctl stats); pend=${st#pending=}; pend=${pend%% *}
    if [[ "$pend" =~ ^[0-9]+$ ]] && (( pend > 0 )) && acquire_lock; then continue; fi
    break
done

trim_log
log "════════ Worker finished: done=$ok failed=$failed ════════"
printf "${C_GREEN}[✓] Queue finished: done=%d failed=%d${C_RESET}\n" "$ok" "$failed"
exit "$QUEUE_ERR"
