#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  master_run.sh — Orchestration controller
#  Handles locks, debug logs, auto-updates, and pipeline execution
#  Supports: Android (Termux) & PC (Linux / macOS / Windows Git Bash)
# ═══════════════════════════════════════════════════════════════════════
set -u

readonly SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Auto-detect Environment
if [ -d "/data/data/com.termux" ] || [ -n "${TERMUX_VERSION:-}" ]; then
    SD="${MEDIA_DIR:-/storage/emulated/0}"
    LOCKFILE="${TMPDIR:-/data/data/com.termux/files/usr/tmp}/media_pipeline.lock"
else
    SD="${MEDIA_DIR:-$HOME/TermuxMedia}"
    LOCKFILE="${TMPDIR:-/tmp}/media_pipeline.lock"
fi

readonly LOG="$SD/Documents/.media_processor.log"
readonly LOG_MAX=$(( 2 * 1024 * 1024 ))

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

# ── 1. Acquire Single-Instance Lock ───────────────────────────────────
mkdir -p "$(dirname "$LOCKFILE")"

if command -v flock &>/dev/null; then
    exec 9>"$LOCKFILE"
    if ! flock -n 9 2>/dev/null; then
        echo "Another instance of master_run is already active." >&2
        exit 0
    fi
else
    # Portable fallback lock (atomic directory lock) for macOS / Git Bash
    LOCKDIR="${LOCKFILE}.dir"
    if ! mkdir "$LOCKDIR" 2>/dev/null; then
        echo "Another instance of master_run is already active." >&2
        exit 0
    fi
    trap 'rm -rf "$LOCKDIR"' EXIT INT TERM HUP
fi

# ── 2. Environment & Log Initialization ───────────────────────────────
mkdir -p "$SD/Documents"
: >> "$LOG"
trim_log
log "════════════ Session Start ════════════"

for bin in ffmpeg ffprobe awk; do
    command -v "$bin" &>/dev/null || {
        printf 'FATAL: "%s" is not installed.\n' "$bin" >&2
        log "FATAL: $bin not found in PATH"
        exit 1
    }
done

# ── 3. Silent Dependency Update ───────────────────────────────────────
log "Updating yt-dlp..."
if command -v yt-dlp &>/dev/null; then
    { yt-dlp -U 2>&1 || pip install --upgrade yt-dlp 2>&1 || python3 -m pip install --upgrade yt-dlp 2>&1 || python -m pip install --upgrade yt-dlp 2>&1 || true; } >> "$LOG"
else
    { pip install yt-dlp 2>&1 || python3 -m pip install yt-dlp 2>&1 || python -m pip install yt-dlp 2>&1 || true; } >> "$LOG"
fi
log "yt-dlp update routine finished."

# ── 4. Execute Move Assets Submodule ──────────────────────────────────
if [[ -f "$SCRIPTS_DIR/move_assets.sh" ]]; then
    log "Invoking move_assets.sh..."
    bash "$SCRIPTS_DIR/move_assets.sh"
else
    log "WARNING: $SCRIPTS_DIR/move_assets.sh not found."
fi

# ── 5. Execute Video Normalizer Submodule ──────────────────────────────
if [[ -f "$SCRIPTS_DIR/normalize.sh" ]]; then
    log "Invoking normalize.sh..."
    bash "$SCRIPTS_DIR/normalize.sh"
else
    log "WARNING: $SCRIPTS_DIR/normalize.sh not found."
fi

trim_log
log "════════════ Session Finished ════════════"
