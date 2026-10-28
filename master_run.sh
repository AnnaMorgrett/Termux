#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  @file        master_run.sh
#  @brief       Central orchestrator for media processing pipeline.
#  @author      Anna Morgrett (https://github.com/AnnaMorgrett/Termux)
#  @license     MIT
#  @version     3.0.0
#
#  Responsibilities:
#  -----------------
#  1. Concurrency control via single-instance process lock.
#  2. Rolling debug log initialization with automated 2MB size cap.
#  3. Prerequisite validation and silent yt-dlp auto-update.
#  4. Sequential invocation of move_assets.sh and normalize.sh.
# ═══════════════════════════════════════════════════════════════════════════════
set -u

# ── Color Output (ANSI) ───────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    C_BLUE='\033[0;34m'
    C_GREEN='\033[0;32m'
    C_YELLOW='\033[0;33m'
    C_RED='\033[0;31m'
    C_BOLD='\033[1m'
    C_RESET='\033[0m'
else
    C_BLUE='' C_GREEN='' C_YELLOW='' C_RED='' C_BOLD='' C_RESET=''
fi

readonly SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Environment & Config ──────────────────────────────────────────────────────
if [[ -d "/data/data/com.termux" || -n "${TERMUX_VERSION:-}" ]]; then
    SD="${MEDIA_DIR:-/storage/emulated/0}"
    LOCKFILE="${TMPDIR:-/data/data/com.termux/files/usr/tmp}/media_pipeline.lock"
else
    SD="${MEDIA_DIR:-$HOME/TermuxMedia}"
    LOCKFILE="${TMPDIR:-/tmp}/media_pipeline.lock"
fi

readonly LOG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/media_processor_log.txt"
readonly LOG_MAX="${LOG_MAX_BYTES:-$(( 2 * 1024 * 1024 ))}"  # 2 MB default

# ── Usage & Help ──────────────────────────────────────────────────────────────
show_help() {
    cat << EOF
Usage: master_run.sh [OPTIONS]

Runs the complete media pipeline: updates dependencies, relocates assets,
and normalizes videos sequentially.

Environment Overrides:
  MEDIA_DIR        Custom root media directory (Default: $SD)
  LOG_MAX_BYTES    Maximum log file size in bytes before rotation (Default: $LOG_MAX)

Options:
  --percent N      Audio peak target for this run: 0 = -9.0 dB ... 100 = -0.1 dB
                   (Target dB = -9 + 8.9 x N/100). Saved default: "q percent N".
  -h, --help       Display this documentation.
EOF
}

if [[ $# -ge 1 && ("$1" == "-h" || "$1" == "--help") ]]; then
    show_help
    exit 0
fi

# --percent N : audio peak target for THIS run only (0 = -9.0 dB ... 100 = -0.1 dB). Saved default: q percent N
if [[ "${1:-}" == "--percent" ]]; then
    if ! [[ "${2:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]] || ! awk -v p="${2:-}" 'BEGIN{exit !(p>=0 && p<=100)}'; then
        echo "Usage: tiktok [--percent 0-100]" >&2; exit 64
    fi
    export PEAK_PERCENT="$2"; shift 2
fi

# ── Logging & Trimming ────────────────────────────────────────────────────────
log() {
    printf '[%s] [MASTER] %s\n' "$(date '+%F %T')" "$*" >> "$LOG"
}

trim_log() {
    local sz
    sz=$(wc -c < "$LOG" 2>/dev/null || echo 0)
    if (( sz > LOG_MAX )); then
        tail -c $(( LOG_MAX / 2 )) "$LOG" > "${LOG}.tmp" && mv -f "${LOG}.tmp" "$LOG"
    fi
}

# ── 1. Acquire Single-Instance Process Lock ───────────────────────────────────
mkdir -p "$(dirname "$LOCKFILE")"

if command -v flock &>/dev/null; then
    exec 9>"$LOCKFILE"
    if ! flock -n 9 2>/dev/null; then
        printf "${C_YELLOW}[!] Another pipeline run is currently in progress. Exiting.${C_RESET}\n" >&2
        exit 0
    fi
else
    # Portable atomic directory lock fallback (macOS, Windows Git Bash)
    LOCKDIR="${LOCKFILE}.dir"
    if ! mkdir "$LOCKDIR" 2>/dev/null; then
        printf "${C_YELLOW}[!] Another pipeline run is currently in progress. Exiting.${C_RESET}\n" >&2
        exit 0
    fi
    trap 'rm -rf "$LOCKDIR"' EXIT INT TERM HUP
fi

# ── 2. Initialize Logs & Validate Dependencies ────────────────────────────────
mkdir -p "$SD/Documents"
: >> "$LOG"
trim_log

log "════════════ Session Start ════════════"

printf "\n${C_BOLD}==================================================${C_RESET}\n"
printf "${C_BOLD}  Media Pipeline Orchestrator                     ${C_RESET}\n"
printf "${C_BOLD}==================================================${C_RESET}\n"

for bin in ffmpeg ffprobe awk; do
    if ! command -v "$bin" &>/dev/null; then
        printf "${C_RED}[FATAL] Required tool '%s' is not found in PATH.${C_RESET}\n" "$bin" >&2
        log "FATAL: Tool $bin missing"
        exit 1
    fi
done

# ── 3. Silent Dependency Update (yt-dlp) ───────────────────────────────────────
printf "${C_BLUE}[1/3] Checking yt-dlp dependencies...${C_RESET}\n"
log "Checking yt-dlp updates..."
if command -v yt-dlp &>/dev/null; then
    { yt-dlp -U 2>&1 || pip install --upgrade yt-dlp 2>&1 || python3 -m pip install --upgrade yt-dlp 2>&1 || python -m pip install --upgrade yt-dlp 2>&1 || true; } >> "$LOG"
else
    { pip install yt-dlp 2>&1 || python3 -m pip install yt-dlp 2>&1 || python -m pip install yt-dlp 2>&1 || true; } >> "$LOG"
fi
log "yt-dlp update routine finished."
printf "${C_GREEN}[✓] yt-dlp is up to date.${C_RESET}\n"

# ── Shared media-scan queue (scripts queue paths, scanned once at the end) ───
export MEDIA_SCAN_QUEUE="$(mktemp)"
# shellcheck source=scan_lib.sh
source "$SCRIPTS_DIR/scan_lib.sh"

# ── 4. Asset Relocation Stage ─────────────────────────────────────────────────
printf "${C_BLUE}[2/3] Invoking asset relocation module...${C_RESET}\n"
if [[ -f "$SCRIPTS_DIR/move_assets.sh" ]]; then
    log "Invoking move_assets.sh..."
    bash "$SCRIPTS_DIR/move_assets.sh"
else
    printf "${C_YELLOW}[!] Warning: %s/move_assets.sh not found.${C_RESET}\n" "$SCRIPTS_DIR"
    log "WARNING: move_assets.sh not found"
fi

# ── 5. Video Stage: queue folder videos, then run the queue worker ───────────
# One pipeline: folder files become queue jobs (originals consumed after a verified
# output), and the worker processes them one at a time. It adds its outputs to
# MEDIA_SCAN_QUEUE, so the single media scan below covers everything from this run.
QUEUE_RC=0
printf "${C_BLUE}[3/3] Queueing videos and running the queue worker...${C_RESET}\n"
if [[ -f "$SCRIPTS_DIR/q.sh" && -f "$SCRIPTS_DIR/worker.sh" ]]; then
    log "Queueing folder videos, then running worker.sh..."
    if bash "$SCRIPTS_DIR/q.sh" scan; then
        bash "$SCRIPTS_DIR/worker.sh" || QUEUE_RC=1
    else
        QUEUE_RC=1
        log "ERROR: queue unavailable; no files were queued, moved or deleted"
        printf "${C_RED}[ERROR] The queue is not working, so videos were NOT processed (no file was touched).${C_RESET}\n" >&2
    fi
else
    printf "${C_YELLOW}[!] q.sh/worker.sh missing; using the old direct mode.${C_RESET}\n"
    log "WARNING: q.sh/worker.sh missing, falling back to normalize.sh"
    bash "$SCRIPTS_DIR/normalize.sh"
fi

scan_queue "$MEDIA_SCAN_QUEUE"
rm -f "$MEDIA_SCAN_QUEUE"

trim_log
log "════════════ Session Finished ════════════"
printf "${C_BOLD}==================================================${C_RESET}\n\n"
exit "${QUEUE_RC:-0}"
