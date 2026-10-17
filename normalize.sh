#!/data/data/com.termux/files/usr/bin/bash
# ═══════════════════════════════════════════════════════════════════════
#  normalize.sh — Video sanitizer, linear audio normalizer (-12 LUFS),
#                 integrity verifier, & media sync
#  Target Location: /storage/emulated/0/Termux/normalize.sh
# ═══════════════════════════════════════════════════════════════════════
set -u

readonly SD="/storage/emulated/0"
readonly INPUT_DIRS=(
    "$SD/DCIM/TikTok"
    "$SD/Download/yt-dlp"
)
readonly VIDEO_OUT="$SD/Movies/NormalizedVideo"
readonly LOG="$SD/Documents/.media_processor.log"
readonly TARGET_LUFS=-12

CURRENT_TMP=""

log() {
    printf '[%s] [NORMALIZE] %s\n' "$(date '+%F %T')" "$*" >> "$LOG"
}

media_scan() {
    local target="$1"
    termux-media-scan "$target" 2>/dev/null \
        || am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE \
               -d "file://$target" >/dev/null 2>&1 \
        || true
}

sanitize_name() {
    local raw_base="${1%.*}"
    local clean
    clean=$(printf '%s' "$raw_base" | LC_ALL=C tr -cs 'A-Za-z0-9_-' '_' | sed 's/^_*//;s/_*$//')
    [[ -z "$clean" ]] && clean="video_$(date +%s)"
    printf '%s.mp4' "$clean"
}

get_unique_dest() {
    local dir="$1" fname="$2"
    local base="${fname%.*}" ext="${fname##*.}" out="$dir/$fname" i=1
    while [[ -e "$out" ]]; do
        out="$dir/${base}_$((i++)).$ext"
    done
    printf '%s' "$out"
}

# ── Clean incomplete temp file on termination ─────────────────────────
trap '[[ -n "$CURRENT_TMP" && -f "$CURRENT_TMP" ]] && rm -f "$CURRENT_TMP"; log "Video processing interrupted"; exit 130' INT TERM HUP

mkdir -p "$VIDEO_OUT"
log "Starting video normalization pass..."
count_ok=0
count_fail=0
count_skip=0

for dir in "${INPUT_DIRS[@]}"; do
    [[ -d "$dir" ]] || continue
    while IFS= read -r -d '' src; do
        orig_name=$(basename "$src")
        clean_name=$(sanitize_name "$orig_name")
        target_path=$(get_unique_dest "$VIDEO_OUT" "$clean_name")
        tmp_path="${target_path%.mp4}.tmp.mp4"
        CURRENT_TMP="$tmp_path"

        log "Processing video: $orig_name"

        # ── Probe video stream codec ─────────────────────────────────
        vcodec=$(ffprobe -v error -select_streams v:0 \
                    -show_entries stream=codec_name -of csv=p=0 \
                    "$src" 2>/dev/null | head -1)

        if [[ -z "$vcodec" ]]; then
            log "  SKIPPED: No video stream detected in $orig_name"
            (( ++count_skip )) || true
            CURRENT_TMP=""
            continue
        fi

        case "$vcodec" in
            h264|hevc|mpeg4) vcodec_args=("-c:v" "copy") ;;
            *)               vcodec_args=("-c:v" "libx264" "-preset" "fast" "-crf" "18" "-pix_fmt" "yuv420p") ;;
        esac

        # ── Probe audio stream ───────────────────────────────────────
        acodec=$(ffprobe -v error -select_streams a:0 \
                    -show_entries stream=codec_name -of csv=p=0 \
                    "$src" 2>/dev/null | head -1)

        if [[ -z "$acodec" ]]; then
            log "  No audio stream detected; remuxing video only"
            if ! ffmpeg -hide_banner -nostats -y \
                    -i "$src" -map 0:v:0 "${vcodec_args[@]}" \
                    -movflags +faststart -an "$tmp_path" 2>>"$LOG"; then
                log "  ERROR: Remux failed for $orig_name"
                rm -f "$tmp_path"
                (( ++count_fail )) || true
                CURRENT_TMP=""
                continue
            fi
        else
            # Pass 1: Measure integrated loudness (LUFS)
            probe_stats=$(ffmpeg -hide_banner -nostats -i "$src" \
                             -af loudnorm=print_format=json \
                             -f null /dev/null 2>&1)
            lufs_val=$(printf '%s' "$probe_stats" \
                       | grep '"input_i"' | head -1 \
                       | sed 's/.*: *"//;s/".*//')

            if [[ -z "$lufs_val" || "$lufs_val" == "-inf" ]]; then
                linear_gain="0.00"
            else
                linear_gain=$(awk "BEGIN {printf \"%.2f\", (${TARGET_LUFS}) - (${lufs_val})}")
            fi
            log "  LUFS: ${lufs_val:-N/A} -> Applying Constant Linear Gain: ${linear_gain} dB"

            # Pass 2: Apply constant linear volume gain (Zero DRC)
            if ! ffmpeg -hide_banner -nostats -y \
                    -i "$src" -map 0:v:0 -map 0:a:0 \
                    "${vcodec_args[@]}" \
                    -af "volume=${linear_gain}dB" -c:a aac -b:a 192k \
                    -movflags +faststart "$tmp_path" 2>>"$LOG"; then
                log "  ERROR: Audio gain render failed for $orig_name"
                rm -f "$tmp_path"
                (( ++count_fail )) || true
                CURRENT_TMP=""
                continue
            fi
        fi

        # ── Output Verification: Non-zero size & valid duration ───────
        out_size=$(wc -c < "$tmp_path" 2>/dev/null || echo 0)
        if (( out_size > 0 )) \
           && ffprobe -v error -i "$tmp_path" \
                  -show_entries format=duration -of csv=p=0 \
                  2>/dev/null | grep -q '[0-9]'; then
            mv -f "$tmp_path" "$target_path"
            rm -f "$src"
            media_scan "$target_path"
            log "  SUCCESS: $orig_name -> $(basename "$target_path") [${out_size} bytes]"
            (( ++count_ok )) || true
        else
            rm -f "$tmp_path"
            log "  ERROR: Verification failed for $orig_name. Source preserved."
            (( ++count_fail )) || true
        fi

        CURRENT_TMP=""
    done < <(find "$dir" -maxdepth 1 -type f \( \
                 -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.webm' \
              -o -iname '*.mov' -o -iname '*.avi' -o -iname '*.3gp'  \
              -o -iname '*.ts'  -o -iname '*.flv' -o -iname '*.m4v'  \
             \) -print0 2>/dev/null)
done

log "Video processing completed. Success: $count_ok, Fail: $count_fail, Skipped: $count_skip"
printf 'Videos: OK=%d  Fail=%d  Skip=%d\n' "$count_ok" "$count_fail" "$count_skip"
