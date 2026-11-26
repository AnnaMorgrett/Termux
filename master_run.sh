#!/usr/bin/env bash
# master_run.sh - Central Termux batch pipeline orchestrator (`tiktok` command).
set -u

if [[ -t 1 ]]; then
    C_BLUE='\033[0;34m' C_GREEN='\033[0;32m' C_YELLOW='\033[0;33m' C_RED='\033[0;31m' C_BOLD='\033[1m' C_RESET='\033[0m'
else
    C_BLUE='' C_GREEN='' C_YELLOW='' C_RED='' C_BOLD='' C_RESET=''
fi

readonly SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SD="${MEDIA_DIR:-/storage/emulated/0}"
readonly BVC2_BIN="${PREFIX:-/data/data/com.termux/files/usr}/opt/ffmpeg-bvc2/bin"
[[ -x "$BVC2_BIN/ffmpeg" && -x "$BVC2_BIN/ffprobe" ]] && export PATH="$BVC2_BIN:$PATH"

readonly LOCKDIR="${TMPDIR:-/data/data/com.termux/files/usr/tmp}/media_pipeline.lock.d"
readonly LOG="$SCRIPTS_DIR/media_processor_log.txt"
readonly LOG_MAX="${LOG_MAX_BYTES:-$(( 2 * 1024 * 1024 ))}"

show_help() {
    cat << EOF
Usage: tiktok [--percent 0-100] [-h]

Scans TikTok and yt-dlp folders, relocates non-video assets, normalizes videos
in FIFO order, and syncs Android's MediaStore.
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { show_help; exit 0; }

if [[ "${1:-}" == "--percent" ]]; then
    if ! [[ "${2:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]] || ! awk -v p="${2:-}" 'BEGIN{exit !(p>=0 && p<=100)}'; then
        echo "Usage: tiktok [--percent 0-100]" >&2
        exit 64
    fi
    export PEAK_PERCENT="$2"
    shift 2
fi

log() { printf '[%s] [MASTER] %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

trim_log() {
    local sz
    sz=$(wc -c < "$LOG" 2>/dev/null || echo 0)
    (( sz > LOG_MAX )) && tail -c $(( LOG_MAX / 2 )) "$LOG" > "${LOG}.tmp" && mv -f "${LOG}.tmp" "$LOG"
    return 0
}

# Atomic mkdir lock with stale-PID recovery
mkdir -p "$(dirname "$LOCKDIR")"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
    owner=$(cat "$LOCKDIR/pid" 2>/dev/null || true)
    if [[ -n "$owner" ]] && kill -0 "$owner" 2>/dev/null; then
        printf "${C_YELLOW}[!] Another pipeline run is already in progress.${C_RESET}\n" >&2
        exit 0
    fi
    rm -rf "$LOCKDIR"
    mkdir "$LOCKDIR" 2>/dev/null || exit 0
fi
echo $$ > "$LOCKDIR/pid"
trap 'rm -rf "$LOCKDIR"' EXIT INT TERM HUP

: >> "$LOG"
trim_log
log "════════════ Session Start ════════════"

printf "\n${C_BOLD}==================================================${C_RESET}\n"
printf "${C_BOLD}  Termux Media Pipeline                           ${C_RESET}\n"
printf "${C_BOLD}==================================================${C_RESET}\n"

for bin in ffmpeg ffprobe awk python3; do
    if ! command -v "$bin" &>/dev/null; then
        printf "${C_RED}[FATAL] Required tool '%s' missing.${C_RESET}\n" "$bin" >&2
        exit 1
    fi
done

printf "${C_BLUE}[1/3] Relocating non-video assets...${C_RESET}\n"
export MEDIA_SCAN_QUEUE="$(mktemp)"
# shellcheck source=media_scan.sh
source "$SCRIPTS_DIR/media_scan.sh"

bash "$SCRIPTS_DIR/move_assets.sh"

printf "${C_BLUE}[2/3] Queueing pending videos & running worker...${C_RESET}\n"
QUEUE_RC=0
if bash "$SCRIPTS_DIR/q.sh" scan; then
    bash "$SCRIPTS_DIR/worker.sh" || QUEUE_RC=1
else
    QUEUE_RC=1
    printf "${C_RED}[ERROR] Queue unavailable; no files were touched.${C_RESET}\n" >&2
fi

printf "${C_BLUE}[3/3] Syncing Android MediaStore...${C_RESET}\n"
scan_queue "$MEDIA_SCAN_QUEUE"
rm -f "$MEDIA_SCAN_QUEUE"

trim_log
log "════════════ Session Finished ════════════"
printf "${C_BOLD}==================================================${C_RESET}\n\n"
exit "${QUEUE_RC:-0}"