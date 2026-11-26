#!/usr/bin/env bash
# worker.sh - Background FIFO queue worker for Termux (no root, no Termux:API).
set -u

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export QUEUE_DIR="${QUEUE_DIR:-$SCRIPT_DIR/data/queue}"
readonly LOG="$SCRIPT_DIR/media_processor_log.txt"
readonly LOG_MAX="${LOG_MAX_BYTES:-$(( 2 * 1024 * 1024 ))}"
readonly LOCK="$QUEUE_DIR/.worker.lock"

# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"
load_config "${PIPELINE_CONFIG:-$SCRIPT_DIR/data/config.conf}"

SCAN_OWN=1
[[ -n "${MEDIA_SCAN_QUEUE:-}" ]] && SCAN_OWN=0
SCANQ="${MEDIA_SCAN_QUEUE:-$QUEUE_DIR/.scan.pending}"

if [[ -t 1 ]]; then
    C_GREEN='\033[0;32m' C_YELLOW='\033[0;33m' C_RED='\033[0;31m' C_BLUE='\033[0;34m' C_RESET='\033[0m'
else
    C_GREEN='' C_YELLOW='' C_RED='' C_BLUE='' C_RESET=''
fi

log() { printf '[%s] [WORKER] %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }
qctl() { python3 "$SCRIPT_DIR/qctl.py" "$@"; }

trim_log() {
    local sz
    sz=$(wc -c < "$LOG" 2>/dev/null || echo 0)
    (( sz > LOG_MAX )) && tail -c $(( LOG_MAX / 2 )) "$LOG" > "$LOG.tmp" && mv -f "$LOG.tmp" "$LOG"
    return 0
}

# shellcheck source=media_scan.sh
source "$SCRIPT_DIR/media_scan.sh"

for bin in python3 ffmpeg ffprobe awk; do
    command -v "$bin" &>/dev/null || { printf "${C_RED}[FATAL] '%s' not found in PATH${C_RESET}\n" "$bin" >&2; exit 1; }
done

mkdir -p "$QUEUE_DIR" 2>/dev/null
if [[ ! -d "$QUEUE_DIR" || ! -w "$QUEUE_DIR" ]]; then
    printf "${C_RED}[ERROR] Queue folder not writable: %s${C_RESET}\n" "$QUEUE_DIR" >&2
    exit 1
fi
: >> "$LOG"

acquire_lock() {
    local owner
    if mkdir "$LOCK" 2>/dev/null; then echo $$ > "$LOCK/pid"; return 0; fi
    [[ -f "$LOCK/pid" ]] || sleep 0.1
    owner=$(cat "$LOCK/pid" 2>/dev/null || true)
    if [[ -n "$owner" ]] && kill -0 "$owner" 2>/dev/null; then return 1; fi
    if [[ -z "$owner" ]] && (( $(date +%s) - $(stat -c %Y "$LOCK" 2>/dev/null || echo 0) < 5 )); then return 1; fi
    rm -rf "$LOCK"
    mkdir "$LOCK" 2>/dev/null && echo $$ > "$LOCK/pid"
}

release_lock() {
    [[ "$(cat "$LOCK/pid" 2>/dev/null)" == "$$" ]] && rm -rf "$LOCK"
    return 0
}

if ! acquire_lock; then
    printf "${C_YELLOW}[!] Worker already running; jobs queued.${C_RESET}\n"
    exit 0
fi

CHILD=""
declare -A RUNNING=()
JOBS_MAX="${WORKER_JOBS:-2}"
[[ "$JOBS_MAX" =~ ^[1-4]$ ]] || JOBS_MAX=2

on_signal() {
    local _id
    for _id in "${!RUNNING[@]}"; do kill "${RUNNING[$_id]}" 2>/dev/null; done
    for _id in "${!RUNNING[@]}"; do
        wait "${RUNNING[$_id]}" 2>/dev/null
        qctl requeue "$_id" >/dev/null 2>&1
        rm -f "$QUEUE_DIR/.jr.$_id" "$QUEUE_DIR/.jo.$_id"
    done
    [[ -n "$CHILD" ]] && kill "$CHILD" 2>/dev/null && wait "$CHILD" 2>/dev/null
    (( SCAN_OWN )) && { scan_queue "$SCANQ"; rm -f "$SCANQ"; }
    release_lock
    exit 143
}
trap on_signal INT TERM HUP
trap 'release_lock' EXIT

run_child() { "$@" & CHILD=$!; wait "$CHILD"; local rc=$?; CHILD=""; return "$rc"; }

normalize_one() {
    local f="$1" keep="$2" rf rc
    local -a extra=()
    rf=$(mktemp "$QUEUE_DIR/.res.XXXXXX")
    [[ "$keep" == "1" ]] && extra=(--keep-original)
    NORMALIZE_RESULT_FILE="$rf" MEDIA_SCAN_QUEUE="$SCANQ" run_child bash "$SCRIPT_DIR/normalize.sh" --file "$f" "${extra[@]}"
    rc=$?
    JOB_OUT=$(sed -n 's/^OUTPUT=//p' "$rf" | head -1)
    rm -f "$rf"
    return "$rc"
}

explain() {
    case "$1" in
        64) echo "invalid configuration" ;;
        1)  echo "processing failed (source kept)" ;;
        2)  echo "no video stream" ;;
        3)  echo "unsupported video (ByteVC2)" ;;
        *)  echo "exit code $1" ;;
    esac
}

process_job() {
    local id="$1" type="$2" keep="$3" value="$4" rawargs="${5:-}" rc p outs="" errs=""
    local -a paths=() dlargs=()
    [[ -n "$rawargs" ]] && IFS=$'\x1f' read -r -a dlargs <<< "$rawargs"
    JOB_OUT=""; JOB_ERR=""

    if [[ "$type" == "file" ]]; then
        [[ -f "$value" ]] || { JOB_ERR="file not found: $value"; return 1; }
        normalize_one "$value" "$keep"; rc=$?
        (( rc == 0 )) && return 0
        JOB_ERR="$(explain "$rc")"; return 1
    fi

    local resf
    resf=$(mktemp "$QUEUE_DIR/.res.XXXXXX")
    DL_RESULT_FILE="$resf" run_child bash "$SCRIPT_DIR/download.sh" "$value" "${dlargs[@]}"; rc=$?
    if (( rc != 0 )); then
        rm -f "$resf"
        JOB_ERR="download failed (exit $rc)"
        return 1
    fi
    while IFS= read -r p; do [[ -n "$p" ]] && paths+=("$p"); done < "$resf"
    rm -f "$resf"
    (( ${#paths[@]} > 0 )) || { JOB_ERR="download produced no file"; return 1; }

    for p in "${paths[@]}"; do
        [[ -f "$p" ]] || { errs+="missing: $(basename "$p"); "; continue; }
        normalize_one "$p" 0; rc=$?
        if (( rc == 0 )); then
            outs+="${JOB_OUT};"
        else
            errs+="$(basename "$p"): $(explain "$rc"); "
        fi
    done

    JOB_OUT="$outs"
    [[ -z "$errs" ]] && return 0
    JOB_ERR="${errs%; }"; return 1
}

run_job_bg() {
    local id="$1" type="$2" keep="$3" value="$4" jargs="$5" buf="$6" jrc
    (
        trap - EXIT
        trap '[[ -n "$CHILD" ]] && kill "$CHILD" 2>/dev/null; exit 143' INT TERM HUP
        (( buf )) && exec >"$QUEUE_DIR/.jo.$id" 2>&1
        if process_job "$id" "$type" "$keep" "$value" "$jargs"; then jrc=0; else jrc=1; fi
        printf '%s\n%s\n%s\n' "$jrc" "$JOB_OUT" "$JOB_ERR" > "$QUEUE_DIR/.jr.$id.tmp" \
            && mv -f "$QUEUE_DIR/.jr.$id.tmp" "$QUEUE_DIR/.jr.$id"
    ) &
    RUNNING[$id]=$!
}

reap_jobs() {
    local id pid res rc out err
    for id in "${!RUNNING[@]}"; do
        pid="${RUNNING[$id]}"; res="$QUEUE_DIR/.jr.$id"
        if [[ ! -f "$res" ]] && kill -0 "$pid" 2>/dev/null; then continue; fi
        wait "$pid" 2>/dev/null
        rc=1; out=""; err="worker subprocess ended unexpectedly"
        if [[ -f "$res" ]]; then
            { IFS= read -r rc; IFS= read -r out; IFS= read -r err; } < "$res"
            rm -f "$res"
        fi
        unset 'RUNNING[$id]'
        if [[ -f "$QUEUE_DIR/.jo.$id" ]]; then cat "$QUEUE_DIR/.jo.$id"; rm -f "$QUEUE_DIR/.jo.$id"; fi
        if [[ "$rc" == "0" ]]; then
            qctl done "$id" --output "$out" >/dev/null
            (( ++ok ))
            log "Job $id DONE"
            printf "${C_GREEN}[job %s] done${C_RESET}\n" "$id"
        else
            qctl fail "$id" "$err" >/dev/null
            (( ++failed ))
            log "Job $id FAILED: $err"
            printf "${C_RED}[job %s] failed: %s${C_RESET}\n" "$id" "$err" >&2
        fi
    done
}

trim_log
log "════════ Worker start (pid $$) ════════"
rec=$(qctl recover 2>&1) || {
    printf "${C_RED}[ERROR] Queue unavailable: %s${C_RESET}\n" "$rec" >&2
    exit 1
}
(( SCAN_OWN )) && { scan_queue "$SCANQ"; rm -f "$SCANQ"; }
rm -f "$QUEUE_DIR/.stop" "$QUEUE_DIR"/.res.* 2>/dev/null

ok=0; failed=0; QUEUE_ERR=0
while :; do
    stopped=0
    while :; do
        while (( ! stopped && ${#RUNNING[@]} < JOBS_MAX )); do
            if [[ -f "$QUEUE_DIR/.stop" ]]; then
                rm -f "$QUEUE_DIR/.stop"
                printf "${C_YELLOW}[!] Stopped by request.${C_RESET}\n"
                stopped=1; break
            fi
            line=$(qctl next --max-running "$JOBS_MAX" 2>&1); nrc=$?
            if (( nrc == 1 )); then
                break
            elif (( nrc != 0 )); then
                printf "${C_RED}[ERROR] Queue problem: %s${C_RESET}\n" "$line" >&2
                QUEUE_ERR=1; stopped=1; break
            fi
            IFS=$'\t' read -r id type keep value jargs <<< "$line"
            printf "${C_BLUE}[job %s]${C_RESET} %s %s\n" "$id" "$type" "$value"
            log "Job $id start: $type $value"
            buf=0
            (( JOBS_MAX > 1 && ${#RUNNING[@]} > 0 )) && buf=1
            run_job_bg "$id" "$type" "$keep" "$value" "${jargs:-}" "$buf"
        done
        (( ${#RUNNING[@]} == 0 )) && break
        wait -n 2>/dev/null || sleep 0.2
        reap_jobs
    done
    (( SCAN_OWN )) && { scan_queue "$SCANQ"; rm -f "$SCANQ"; }
    (( stopped )) && break
    release_lock
    st=$(qctl stats)
    pend=${st#pending=}; pend=${pend%% *}
    if [[ "$pend" =~ ^[0-9]+$ ]] && (( pend > 0 )) && acquire_lock; then
        continue
    fi
    break
done

trim_log
log "════════ Worker finished: done=$ok failed=$failed ════════"
printf "${C_GREEN}[✓] Queue finished: done=%d failed=%d${C_RESET}\n" "$ok" "$failed"
exit "$QUEUE_ERR"