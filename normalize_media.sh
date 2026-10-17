#!/data/data/com.termux/files/usr/bin/bash
# ═══════════════════════════════════════════════════════════════════════
#  Termux Media Processor
#  — Audio normalization (-12 LUFS, linear gain) & asset management
# ═══════════════════════════════════════════════════════════════════════
set -u

# ── Configuration ─────────────────────────────────────────────────────
readonly SD="/storage/emulated/0"
readonly INPUT_DIRS=(
    "$SD/DCIM/TikTok"
    "$SD/Download/yt-dlp"
)
readonly ASSET_OUT="$SD/Pictures/TikTok_Assets"
readonly VIDEO_OUT="$SD/Movies/NormalizedVideo"
readonly LOG="$SD/Documents/.media_processor.log"
readonly LOCKFILE="${TMPDIR:-/data/data/com.termux/files/usr/tmp}/media_proc.lock"
readonly LOG_MAX=$(( 2 * 1024 * 1024 ))   # 2 MB
readonly TARGET_LUFS=-12

# ── Dependency gate ───────────────────────────────────────────────────
for _cmd in ffmpeg ffprobe awk; do
    command -v "$_cmd" &>/dev/null || {
        printf 'FATAL: %s not found. Install: pkg install ffmpeg\n' "$_cmd" >&2
        exit 1
    }
done

# ── Single-instance lock (flock) ─────────────────────────────────────
exec 9>"$LOCKFILE"
if ! flock -n 9 2>/dev/null; then
    echo "Another instance is already running." >&2
    exit 0
fi

# ── Trap: clean temp file on interrupt ────────────────────────────────
CURRENT_TMP=""
_cleanup() {
    [[ -n "$CURRENT_TMP" && -f "$CURRENT_TMP" ]] && rm -f "$CURRENT_TMP"
    log "Session interrupted by signal"
    exit 130
}
trap _cleanup INT TERM HUP

# ═══════════════════════════════════════════════════════════════════════
#  LOGGING
# ═══════════════════════════════════════════════════════════════════════
mkdir -p "$(dirname "$LOG")"
: >> "$LOG"

trim_log() {
    local sz
    sz=$(wc -c < "$LOG" 2>/dev/null || echo 0)
    if (( sz > LOG_MAX )); then
        # Keep the newest half — trim oldest data
        tail -c $(( LOG_MAX / 2 )) "$LOG" > "${LOG}.tmp" && mv -f "${LOG}.tmp" "$LOG"
    fi
}

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

# ═══════════════════════════════════════════════════════════════════════
#  HELPERS
# ═══════════════════════════════════════════════════════════════════════

# Trigger Android MediaScanner for a single file path
media_scan() {
    termux-media-scan "$1" 2>/dev/null \
        || am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE \
               -d "file://$1" >/dev/null 2>&1 \
        || true
}

# Sanitize a basename → letters, digits, dash, underscore only; output .mp4
sanitize_name() {
    local base="${1%.*}"
    base=$(printf '%s' "$base" | LC_ALL=C tr -cs 'A-Za-z0-9_-' '_' | sed 's/^__*//;s/__*$//')
    [[ -z "$base" ]] && base="video_$(date +%s)"
    printf '%s.mp4' "$base"
}

# Return a non-colliding path inside a target directory
unique_dest() {
    local dir="$1" name="$2"
    local base="${name%.*}" ext="${name##*.}" out="$dir/$name" i=1
    while [[ -e "$out" ]]; do
        out="$dir/${base}_$((i++)).$ext"
    done
    printf '%s' "$out"
}

# ═══════════════════════════════════════════════════════════════════════
#  STEP 1 — Initialise & trim log
# ═══════════════════════════════════════════════════════════════════════
trim_log
log "═══ Session start ═══"

# ═══════════════════════════════════════════════════════════════════════
#  STEP 2 — Auto-update yt-dlp (silent)
# ═══════════════════════════════════════════════════════════════════════
log "Updating yt-dlp..."
if command -v yt-dlp &>/dev/null; then
    { yt-dlp -U 2>&1 || pip install -U yt-dlp 2>&1 || true; } >> "$LOG"
else
    { pip install yt-dlp 2>&1 || true; } >> "$LOG"
fi
log "yt-dlp update done"

# ═══════════════════════════════════════════════════════════════════════
#  STEP 3 + 4 — Move non-video assets → Pictures/TikTok_Assets & scan
# ═══════════════════════════════════════════════════════════════════════
log "--- Asset pass ---"
mkdir -p "$ASSET_OUT"
asset_count=0

for dir in "${INPUT_DIRS[@]}"; do
    [[ -d "$dir" ]] || continue
    while IFS= read -r -d '' src; do
        name=$(basename "$src")
        dest=$(unique_dest "$ASSET_OUT" "$name")
        if mv -n "$src" "$dest" 2>/dev/null; then
            media_scan "$dest"
            log "ASSET  OK : $name → $(basename "$dest")"
            (( ++asset_count )) || true
        else
            log "ASSET ERR: failed to move $name"
        fi
    done < <(find "$dir" -maxdepth 1 -type f \( \
                 -iname '*.jpg'  -o -iname '*.jpeg' -o -iname '*.png'  \
              -o -iname '*.gif'  -o -iname '*.webp' -o -iname '*.bmp'  \
              -o -iname '*.tiff' -o -iname '*.tif'  -o -iname '*.heic' \
              -o -iname '*.heif' -o -iname '*.svg'                     \
             \) -print0 2>/dev/null)
done
log "Assets moved: $asset_count"

# ═══════════════════════════════════════════════════════════════════════
#  STEP 5 + 6 + 7 + 8 — Video processing pipeline
#    5  Scan & sanitize filenames
#    6  Normalize audio to −12 LUFS (constant linear gain, no DRC)
#    7  Save to NormalizedVideo; delete original only after verification
#    8  MediaScanner trigger per video
# ═══════════════════════════════════════════════════════════════════════
log "--- Video pass ---"
mkdir -p "$VIDEO_OUT"
v_ok=0; v_fail=0; v_skip=0

for dir in "${INPUT_DIRS[@]}"; do
    [[ -d "$dir" ]] || continue
    while IFS= read -r -d '' src; do
        orig=$(basename "$src")
        safe=$(sanitize_name "$orig")
        dest=$(unique_dest "$VIDEO_OUT" "$safe")
        tmp="${dest%.mp4}.tmp.mp4"
        CURRENT_TMP="$tmp"
        log "VIDEO: $orig"

        # ── Probe video codec ────────────────────────────────────────
        vcodec=$(ffprobe -v error -select_streams v:0 \
                    -show_entries stream=codec_name -of csv=p=0 \
                    "$src" 2>/dev/null | head -1)
        if [[ -z "$vcodec" ]]; then
            log "  SKIP: no video stream detected"
            (( ++v_skip )) || true; CURRENT_TMP=""; continue
        fi

        # Copy-safe codecs for MP4 container; else re-encode
        case "$vcodec" in
            h264|hevc|mpeg4) cv=("-c:v" "copy") ;;
            *)               cv=("-c:v" "libx264" "-preset" "fast"
                                 "-crf" "18" "-pix_fmt" "yuv420p") ;;
        esac

        # ── Probe audio stream ───────────────────────────────────────
        acodec=$(ffprobe -v error -select_streams a:0 \
                    -show_entries stream=codec_name -of csv=p=0 \
                    "$src" 2>/dev/null | head -1)

        if [[ -z "$acodec" ]]; then
            # ---- No audio: remux / re-encode video only ----
            log "  No audio stream — remuxing video only"
            if ! ffmpeg -hide_banner -nostats -y \
                    -i "$src" -map 0:v:0 "${cv[@]}" \
                    -movflags +faststart -an "$tmp" 2>>"$LOG"; then
                log "  FAIL: ffmpeg error (no-audio path)"
                rm -f "$tmp"; (( ++v_fail )) || true; CURRENT_TMP=""; continue
            fi
        else
            # ---- Pass 1: measure integrated loudness (LUFS) ----
            json=$(ffmpeg -hide_banner -nostats -i "$src" \
                       -af loudnorm=print_format=json \
                       -f null /dev/null 2>&1)
            lufs=$(printf '%s' "$json" \
                   | grep '"input_i"' | head -1 \
                   | sed 's/.*: *"//;s/".*//')

            if [[ -z "$lufs" || "$lufs" == "-inf" ]]; then
                log "  WARN: LUFS measurement returned ${lufs:-empty} — applying 0 dB gain"
                gain="0.00"
            else
                gain=$(awk "BEGIN {printf \"%.2f\", (${TARGET_LUFS}) - (${lufs})}")
            fi
            log "  Measured: ${lufs:-n/a} LUFS → gain: ${gain} dB"

            # ---- Pass 2: apply constant linear volume gain ----
            if ! ffmpeg -hide_banner -nostats -y \
                    -i "$src" -map 0:v:0 -map 0:a:0 \
                    "${cv[@]}" \
                    -af "volume=${gain}dB" -c:a aac -b:a 192k \
                    -movflags +faststart "$tmp" 2>>"$LOG"; then
                log "  FAIL: ffmpeg encode error"
                rm -f "$tmp"; (( ++v_fail )) || true; CURRENT_TMP=""; continue
            fi
        fi

        # ── Verify output integrity ──────────────────────────────────
        out_sz=$(wc -c < "$tmp" 2>/dev/null || echo 0)
        if (( out_sz > 0 )) \
           && ffprobe -v error -i "$tmp" \
                  -show_entries format=duration -of csv=p=0 \
                  2>/dev/null | grep -q '[0-9]'; then
            mv -f "$tmp" "$dest"
            rm -f "$src"
            media_scan "$dest"
            log "  OK  : $(basename "$dest")  [${out_sz} bytes]"
            (( ++v_ok )) || true
        else
            rm -f "$tmp"
            log "  FAIL: output verification failed — original kept"
            (( ++v_fail )) || true
        fi
        CURRENT_TMP=""

    done < <(find "$dir" -maxdepth 1 -type f \( \
                 -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.webm' \
              -o -iname '*.mov' -o -iname '*.avi' -o -iname '*.3gp'  \
              -o -iname '*.ts'  -o -iname '*.flv' -o -iname '*.m4v'  \
             \) -print0 2>/dev/null)
done

log "Videos — OK: $v_ok  Failed: $v_fail  Skipped: $v_skip"

# ═══════════════════════════════════════════════════════════════════════
#  Finalise
# ═══════════════════════════════════════════════════════════════════════
trim_log
log "═══ Session complete ═══"
printf 'Done.  Videos: OK=%d  Fail=%d  Skip=%d  |  Assets moved: %d\n' \
       "$v_ok" "$v_fail" "$v_skip" "$asset_count"
