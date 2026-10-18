#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  @file        normalize.sh
#  @brief       Video sanitizer, constant linear audio normalizer (-12 LUFS),
#               output integrity verifier, and Android MediaScanner trigger.
#  @author      Anna Morgrett (https://github.com/AnnaMorgrett/Termux)
#  @license     MIT
#  @version     2.2.0
# ═══════════════════════════════════════════════════════════════════════════════
set -u

# ── Color Output (ANSI) ───────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    C_BLUE='\033[0;34m'
    C_GREEN='\033[0;32m'
    C_YELLOW='\033[0;33m'
    C_RED='\033[0;31m'
    C_CYAN='\033[0;36m'
    C_RESET='\033[0m'
else
    C_BLUE='' C_GREEN='' C_YELLOW='' C_RED='' C_CYAN='' C_RESET=''
fi

# ── Environment & Config ──────────────────────────────────────────────────────
if [[ -d "/data/data/com.termux" || -n "${TERMUX_VERSION:-}" ]]; then
    SD="${MEDIA_DIR:-/storage/emulated/0}"
else
    SD="${MEDIA_DIR:-$HOME/TermuxMedia}"
fi

readonly INPUT_DIRS=(
    "$SD/DCIM/TikTok"
    "$SD/Download/yt-dlp"
)
readonly VIDEO_OUT="$SD/Movies/NormalizedVideo"
readonly LOG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/media_processor_log.txt"


readonly TARGET_LUFS="${TARGET_LUFS:--12}"
readonly AUDIO_BITRATE="${AUDIO_BITRATE:-192k}"

CURRENT_TMP=""

# ── Usage & Help ──────────────────────────────────────────────────────────────
show_help() {
    cat << H_EOF
Usage: normalize.sh [OPTIONS]

Scans TikTok and yt-dlp folders for video files, normalizes audio to -12 LUFS
using pure constant linear gain (strictly no dynamic range compression), sanitizes
filenames, and verifies file integrity before deleting the original.

Scanned Directories:
  - $SD/DCIM/TikTok
  - $SD/Download/yt-dlp

Target Directory:
  - $VIDEO_OUT

Supported Formats:
  MP4, MKV, WEBM, MOV, AVI, 3GP, TS, FLV, M4V

Environment Overrides:
  TARGET_LUFS      Target loudness in LUFS (Default: -12)
  AUDIO_BITRATE    Audio bitrate for normalized AAC stream (Default: 192k)
  MEDIA_DIR        Custom root media directory (Default: $SD)

Options:
  -h, --help       Display this documentation.
H_EOF
}

if [[ $# -ge 1 && ("$1" == "-h" || "$1" == "--help") ]]; then
    show_help
    exit 0
fi

# ── Utilities ─────────────────────────────────────────────────────────────────
log() {
    printf '[%s] [NORMALIZE] %s\n' "$(date '+%F %T')" "$*" >> "$LOG"
}

media_scan() {
    local target="$1"
    if command -v termux-media-scan &>/dev/null; then
        termux-media-scan "$target" </dev/null >/dev/null 2>&1 || true
    elif command -v am &>/dev/null; then
        am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE \
               -d "file://$target" </dev/null >/dev/null 2>&1 || true
    fi
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

# ── Cleanup Handler ───────────────────────────────────────────────────────────
trap '[[ -n "$CURRENT_TMP" && -f "$CURRENT_TMP" ]] && rm -f "$CURRENT_TMP"; log "Video processing interrupted"; exit 130' INT TERM HUP

# ── Execution ─────────────────────────────────────────────────────────────────
mkdir -p "$VIDEO_OUT" "$(dirname "$LOG")"
log "Beginning video normalization stage..."
printf "${C_BLUE}[*] Scanning for pending videos... (normalize.sh v2.2.0)${C_RESET}\n"

count_ok=0
count_fail=0
count_skip=0
count_bvc2=0

for dir in "${INPUT_DIRS[@]}"; do
    [[ -d "$dir" ]] || continue
    while IFS= read -r -d '' src <&3; do
        orig_name=$(basename "$src")
        clean_name=$(sanitize_name "$orig_name")
        target_path=$(get_unique_dest "$VIDEO_OUT" "$clean_name")
        tmp_path="${target_path%.mp4}.tmp.mp4"
        CURRENT_TMP="$tmp_path"

        printf "${C_CYAN}[*] Processing:${C_RESET} %s\n" "$orig_name"
        log "Processing video: $orig_name"

        # ── 1. Probe Video Codec ──────────────────────────────────────
        # Count real video streams first (works even when codec is unknown)
        vstreams=$(ffprobe -v error -show_entries stream=codec_type \
                      -of csv=p=0 "$src" 2>/dev/null | grep -c '^video')
        vcodec=$(ffprobe -v error -select_streams v:0 \
                    -show_entries stream=codec_name -of csv=p=0 \
                    "$src" 2>/dev/null | head -1)
        vtag=$(ffprobe -v error -select_streams v:0 \
                    -show_entries stream=codec_tag_string -of csv=p=0 \
                    "$src" 2>/dev/null | head -1)

        if (( vstreams == 0 )); then
            printf "  ${C_YELLOW}[SKIP] No video stream detected.${C_RESET}\n"
            log "  SKIPPED: No video stream detected in $orig_name"
            (( ++count_skip )) || true
            CURRENT_TMP=""
            continue
        fi

        # ByteVC2 (bvc2): ffmpeg can't decode it, but the stream can be copied
        # untouched into a MOV-muxed (isom brand) file while only the audio is
        # normalized. Video bytes stay identical; verified by MD5 below.
        bvc2_mode=0
        mux_args=(-movflags +faststart)
        if [[ -z "$vcodec" || "$vcodec" == "none" || "$vcodec" == "unknown" \
              || "$vtag" == bvc* ]]; then
            bvc2_mode=1
            vcodec_args=(-c:v copy -tag:v "${vtag:-bvc2}")
            mux_args=(-movflags +faststart -f mov -brand isom)
            printf "  ${C_YELLOW}[bvc2] ByteVC2 video: copying video untouched, normalizing audio only.${C_RESET}\n"
            log "  BVC2 passthrough: $orig_name codec=${vcodec:-?} tag=${vtag:-?}"
        else
            case "$vcodec" in
                h264|hevc|mpeg4) vcodec_args=("-c:v" "copy") ;;
                *)               vcodec_args=("-c:v" "libx264" "-preset" "fast" "-crf" "18" "-pix_fmt" "yuv420p") ;;
            esac
        fi

        # ── 2. Probe Audio Codec ──────────────────────────────────────
        acodec=$(ffprobe -v error -select_streams a:0 \
                    -show_entries stream=codec_name -of csv=p=0 \
                    "$src" 2>/dev/null | head -1)

        if [[ -z "$acodec" ]]; then
            printf "  ${C_YELLOW}[Audio] Stream absent; remuxing video only.${C_RESET}\n"
            log "  No audio stream detected; remuxing video only"
            if ! ffmpeg -hide_banner -nostdin -nostats -y \
                    -i "$src" -map 0:v:0 "${vcodec_args[@]}" \
                    "${mux_args[@]}" -an "$tmp_path" 2>>"$LOG"; then
                printf "  ${C_RED}[ERROR] Remux operation failed.${C_RESET}\n" >&2
                log "  ERROR: Remux failed for $orig_name"
                rm -f "$tmp_path"
                (( ++count_fail )) || true
                CURRENT_TMP=""
                continue
            fi
        else
            # ── 3. Pass 1: Measure Integrated Loudness (LUFS) ─────────
            probe_stats=$(ffmpeg -hide_banner -nostdin -nostats -i "$src" \
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

            printf "  ${C_BLUE}[Audio] Measured:${C_RESET} %s LUFS -> ${C_BLUE}Linear Gain:${C_RESET} %s dB (Target: %s LUFS)\n" \
                   "${lufs_val:-N/A}" "$linear_gain" "$TARGET_LUFS"
            log "  LUFS: ${lufs_val:-N/A} -> Applying Constant Linear Gain: ${linear_gain} dB"

            # ── 4. Pass 2: Apply Constant Linear Gain (Zero DRC) ──────
            if ! ffmpeg -hide_banner -nostdin -nostats -y \
                    -i "$src" -map 0:v:0 -map 0:a:0 \
                    "${vcodec_args[@]}" \
                    -af "volume=${linear_gain}dB" -c:a aac -b:a "$AUDIO_BITRATE" \
                    "${mux_args[@]}" "$tmp_path" 2>>"$LOG"; then
                printf "  ${C_YELLOW}[!] Audio too short/corrupt. Using safe copy...${C_RESET}\n"
                log "  WARNING: Audio gain render failed for $orig_name. Attempting -c:a copy fallback."
                if ! ffmpeg -hide_banner -nostdin -nostats -y \
                        -i "$src" -map 0:v:0 -map 0:a:0 \
                        "${vcodec_args[@]}" -c:a copy \
                        "${mux_args[@]}" "$tmp_path" 2>>"$LOG"; then
                    printf "  ${C_YELLOW}[!] Audio completely unreadable. Stripping audio to save video...${C_RESET}\n"
                    log "  WARNING: Safe copy failed for $orig_name. Attempting -an (video only) fallback."
                    if ! ffmpeg -hide_banner -nostdin -nostats -y \
                            -i "$src" -map 0:v:0 \
                            "${vcodec_args[@]}" -an \
                            "${mux_args[@]}" "$tmp_path" 2>>"$LOG"; then
                        printf "  ${C_RED}[ERROR] Ultimate fallback failed. File unprocessable.${C_RESET}\n" >&2
                        log "  ERROR: Ultimate fallback failed for $orig_name"
                        rm -f "$tmp_path"
                        (( ++count_fail )) || true
                        CURRENT_TMP=""
                        continue
                    fi
                fi
            fi
        fi

        # ── 5. Verification & Atomic Commit ───────────────────────────
        out_size=$(wc -c < "$tmp_path" 2>/dev/null || echo 0)
        vid_ok=1
        if (( bvc2_mode == 1 )) && [[ -f "$tmp_path" ]]; then
            md_src=$(ffmpeg -v error -nostdin -i "$src" -map 0:v:0 -c copy -f md5 - 2>/dev/null </dev/null)
            md_out=$(ffmpeg -v error -nostdin -i "$tmp_path" -map 0:v:0 -c copy -f md5 - 2>/dev/null </dev/null)
            [[ -n "$md_src" && "$md_src" == "$md_out" ]] || vid_ok=0
        fi
        if (( out_size > 0 && vid_ok == 1 )) \
           && ffprobe -v error -i "$tmp_path" \
                  -show_entries format=duration -of csv=p=0 \
                  2>/dev/null | grep -q '[0-9]'; then
            mv -f "$tmp_path" "$target_path"
            rm -f "$src"
            media_scan "$target_path"
            printf "  ${C_GREEN}[✓] Verified & Saved:${C_RESET} %s (%s bytes)\n" "$(basename "$target_path")" "$out_size"
            log "  SUCCESS: $orig_name -> $(basename "$target_path") [${out_size} bytes]"
            (( ++count_ok )) || true
            (( bvc2_mode == 1 )) && { (( ++count_bvc2 )) || true; }
        else
            rm -f "$tmp_path"
            printf "  ${C_RED}[ERROR] Verification check failed. Source file preserved.${C_RESET}\n" >&2
            log "  ERROR: Verification failed for $orig_name. Source preserved."
            (( ++count_fail )) || true
        fi

        CURRENT_TMP=""
    done 3< <(find "$dir" -maxdepth 1 -type f \( \
                 -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.webm' \
              -o -iname '*.mov' -o -iname '*.avi' -o -iname '*.3gp'  \
              -o -iname '*.ts'  -o -iname '*.flv' -o -iname '*.m4v'  \
             \) -print0 2>/dev/null)
done

log "Video normalization finished. Success: $count_ok, Fail: $count_fail, Skipped: $count_skip, ByteVC2 passthrough: $count_bvc2"
printf "${C_GREEN}[✓] Summary: Videos OK=%d, Failed=%d, Skipped=%d, ByteVC2(audio-only fix)=%d${C_RESET}\n" "$count_ok" "$count_fail" "$count_skip" "$count_bvc2"
