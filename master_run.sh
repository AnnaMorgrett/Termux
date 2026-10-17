#!/data/data/com.termux/files/usr/bin/bash
# ═══════════════════════════════════════════════════════════════════════
#  master_run.sh — Orchestration controller
#  Handles locks, debug logs, auto-updates, and pipeline execution
#  Target Location: /storage/emulated/0/Termux/master_run.sh
# ═══════════════════════════════════════════════════════════════════════
set -u

readonly SD="/storage/emulated/0"
readonly SCRIPTS_DIR="$SD/Termux"
readonly LOG="$SD/Documents/.media_processor.log"
readonly LOCKFILE="${TMPDIR:-/data/data/com.termux/files/usr/tmp}/media_pipeline.lock"
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
exec 9>"$LOCKFILE"
if ! flock -n 9 2>/dev/null; then
    echo "Another instance of master_run is already active." >&2
    exit 0
fi

# ── 2. Environment & Log Initialization ───────────────────────────────
mkdir -p "$(dirname "$LOG")"
: >> "$LOG"
trim_log
log "════════════ Session Start ════════════"

for bin in ffmpeg ffprobe awk; do
    command -v "$bin" &>/dev/null || {
        printf 'FATAL: "%s" is not installed. Run: pkg install ffmpeg\n' "$bin" >&2
        log "FATAL: $bin not found in PATH"
        exit 1
    }
done

# ── 3. Silent Dependency Update ───────────────────────────────────────
log "Updating yt-dlp..."
if command -v yt-dlp &>/dev/null; then
    { yt-dlp -U 2>&1 || pip install --upgrade yt-dlp 2>&1 || true; } >> "$LOG"
else
    { pip install yt-dlp 2>&1 || true; } >> "$LOG"
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
