#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  @file        master_run.sh
#  @brief       Central orchestrator for media processing pipeline.
#  @author      Anna Morgrett (https://github.com/AnnaMorgrett/Termux)
#  @license     MIT
#  @version     2.1.0
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
  -h, --help       Display this documentation.
EOF
}

if [[ $# -ge 1 && ("$1" == "-h" || "$1" == "--help") ]]; then
    show_help
    exit 0
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
scan_queue() {
    # Scan every queued file in ONE call (deduped, existing files only).
    local qf="$1" f out rc=1 i
    local -a files=() chunk=()
    [[ -s "$qf" ]] || return 0
    while IFS= read -r f; do
        [[ -f "$f" ]] && files+=("$f")
    done < <(sort -u "$qf")
    (( ${#files[@]} > 0 )) || return 0
    if command -v termux-media-scan &>/dev/null; then
        rc=0
        for (( i=0; i<${#files[@]}; i+=50 )); do
            chunk=("${files[@]:i:50}")
            out=$(termux-media-scan "${chunk[@]}" </dev/null 2>&1) || rc=$?
        done
    elif command -v am &>/dev/null; then
        rc=0
        for f in "${files[@]}"; do
            am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE \
               -d "file://$f" </dev/null >/dev/null 2>&1 || rc=$?
        done
    else
        out="no termux-media-scan or am found"
    fi
    if (( rc == 0 )); then
        printf "${C_GREEN}[✓] Media scan:${C_RESET} %d file(s) added to gallery\n" "${#files[@]}"
    else
        printf "${C_YELLOW}[!] Media scan failed (install Termux:API app + 'pkg install termux-api'): %s${C_RESET}\n" "${out:-}" >&2
    fi
}

# ── 4. Asset Relocation Stage ─────────────────────────────────────────────────
printf "${C_BLUE}[2/3] Invoking asset relocation module...${C_RESET}\n"
if [[ -f "$SCRIPTS_DIR/move_assets.sh" ]]; then
    log "Invoking move_assets.sh..."
    bash "$SCRIPTS_DIR/move_assets.sh"
else
    printf "${C_YELLOW}[!] Warning: %s/move_assets.sh not found.${C_RESET}\n" "$SCRIPTS_DIR"
    log "WARNING: move_assets.sh not found"
fi

# ── 5. Video Normalization Stage ──────────────────────────────────────────────
printf "${C_BLUE}[3/3] Invoking video normalization module...${C_RESET}\n"
if [[ -f "$SCRIPTS_DIR/normalize.sh" ]]; then
    log "Invoking normalize.sh..."
    bash "$SCRIPTS_DIR/normalize.sh"
else
    printf "${C_YELLOW}[!] Warning: %s/normalize.sh not found.${C_RESET}\n" "$SCRIPTS_DIR"
    log "WARNING: normalize.sh not found"
fi

scan_queue "$MEDIA_SCAN_QUEUE"
rm -f "$MEDIA_SCAN_QUEUE"

trim_log
log "════════════ Session Finished ════════════"
printf "${C_BOLD}==================================================${C_RESET}\n\n"
