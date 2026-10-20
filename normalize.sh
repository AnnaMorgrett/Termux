#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  @file        normalize.sh
#  @brief       Video sanitizer, constant linear audio normalizer (-12 LUFS),
#               output integrity verifier, and Android MediaScanner trigger.
#  @author      Anna Morgrett (https://github.com/AnnaMorgrett/Termux)
#  @license     MIT
#  @version     2.4.2
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

# ── Deferred media scan: queue now, scan once at the end ─────────────────────
if [[ -n "${MEDIA_SCAN_QUEUE:-}" ]]; then
    SCAN_QUEUE="$MEDIA_SCAN_QUEUE"; SCAN_OWNER=0   # master_run scans at the very end
else
    SCAN_QUEUE="$(mktemp)"; SCAN_OWNER=1           # standalone run: scan at our end
fi
queue_scan() { printf '%s\n' "$1" >> "$SCAN_QUEUE"; }
scan_queue() {
    # Scan every queued file in ONE call (deduped, existing files only).
    local qf="$1" f out rc=1 i
    local -a files=() chunk=()
    [[ -s "$qf" ]] || return 0
    while IFS= read -r f; do
        [[ -f "$f" ]] && files+=("$f")
    done < <(sort -u "$qf" | while IFS= read -r q; do
                [[ -f "$q" ]] && printf '%s\t%s\n' "$(stat -c %Y "$q" 2>/dev/null || echo 0)" "$q"
             done | sort -t "$(printf '\t')" -k1,1n -s | cut -f2-)
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

redownload_h264() {
    # ByteVC2 can't be decoded/played by ffmpeg, WhatsApp or most players.
    # Re-fetch the same TikTok video as H.264 via yt-dlp (user + id come from
    # the filename). The bvc2 original is deleted ONLY after the new file is
    # verified (h264/hevc codec + full decode with zero errors).
    local stem="$1" src="$2" id user url tmpd out vc ferr ytmsg
    REDL_REASON=""
    # name format: user_YYYY-MM-DD_ID, optionally followed by " (1)" duplicate suffix
    if [[ "$stem" =~ ^(.+)_[0-9]{4}-[0-9]{2}-[0-9]{2}_([0-9]{15,})([[:space:]]*\([0-9]+\))?$ ]]; then
        user="${BASH_REMATCH[1]}"; id="${BASH_REMATCH[2]}"
    else
        REDL_REASON="filename has no user/date/ID pattern"; return 1
    fi
    if ! command -v yt-dlp &>/dev/null; then
        REDL_REASON="yt-dlp not found"; return 1
    fi
    url="https://www.tiktok.com/@${user}/video/${id}"
    tmpd=$(mktemp -d "$SD/Download/.redl.XXXXXX") || return 1
    printf "  ${C_BLUE}[~] Re-downloading as H.264:${C_RESET} %s\n" "$url"
    log "  REDOWNLOAD: $url"
    # H.264 first, HEVC as fallback; never the watermarked "download" format.
    # Two attempts: TikTok's JS challenge occasionally fails once and works again.
    local attempt
    for attempt in 1 2; do
        yt-dlp --no-mtime -S "vcodec:h264,res,acodec:m4a" \
               -f "b[vcodec^=h264][format_id!=download]/b[vcodec~='^(h265|hevc)'][format_id!=download]" \
               -o "$tmpd/%(id)s.%(ext)s" "$url" </dev/null > "$tmpd/yt.log" 2>&1
        cat "$tmpd/yt.log" >> "$LOG" 2>/dev/null
        out=$(find "$tmpd" -maxdepth 1 -type f -name '*.mp4' | head -1)
        [[ -n "$out" ]] && break
        (( attempt == 1 )) && { printf "  ${C_YELLOW}[~] Retrying once...${C_RESET}\n"; sleep 3; }
    done
    if [[ -z "$out" ]]; then
        ytmsg=$(grep -E "ERROR|WARNING" "$tmpd/yt.log" | tail -1 | cut -c1-160)
        REDL_REASON="yt-dlp: ${ytmsg:-no output, no error line}"
        rm -rf "$tmpd"; return 1
    fi
    vc=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name \
            -of csv=p=0 "$out" </dev/null 2>/dev/null | head -1)
    ferr=$(ffmpeg -v error -nostdin -i "$out" -f null - </dev/null 2>&1 | head -3)
    if [[ "$vc" =~ ^(h264|hevc)$ && -z "$ferr" ]]; then
        touch -r "$src" "$out" 2>/dev/null || true
        mv -f "$out" "$(dirname "$src")/${stem}_h264.mp4" && rm -f "$src"
        rm -rf "$tmpd"
        log "  REDOWNLOAD OK ($vc): $stem -> ${stem}_h264.mp4; bvc2 original removed"
        return 0
    fi
    REDL_REASON="downloaded file rejected (codec=${vc:-?}${ferr:+, decode errors})"
    log "  REDOWNLOAD REJECTED (codec=${vc:-?} err=${ferr:-none}) for $stem"
    rm -rf "$tmpd"; return 1
}

sanitize_name() {
    local raw_base="${1%.*}"
    local clean
    clean=$(printf '%s' "$raw_base" | LC_ALL=C tr -cs 'A-Za-z0-9_-' '_' | sed 's/^_*//;s/_*$//')
    clean="${clean:0:120}"; clean="${clean%_}"
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
printf "${C_BLUE}[*] Scanning for pending videos... (normalize.sh v2.4.2)${C_RESET}\n"

count_ok=0
count_fail=0
count_skip=0
count_bvc2=0
count_unsup=0

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

        bvc2_mode=0
        mux_args=(-movflags +faststart)
        if [[ -z "$vcodec" || "$vcodec" == "none" || "$vcodec" == "unknown" \
              || "$vtag" == bvc* ]]; then
            if [[ -n "${NORMALIZE_PASS2:-}" ]]; then   # 2nd pass: no repeat downloads
                (( ++count_unsup )) || true; CURRENT_TMP=""; continue
            fi
            printf "  ${C_YELLOW}[bvc2] ByteVC2 video - not playable by most players.${C_RESET}\n"
            if redownload_h264 "${orig_name%.*}" "$src"; then
                printf "  ${C_GREEN}[✓] Replaced with verified H.264 copy (normalized in the pass below).${C_RESET}\n"
                (( ++count_bvc2 )) || true
            else
                printf "  ${C_YELLOW}[!] Could not get an H.264 copy (%s). Original kept untouched.${C_RESET}\n" "${REDL_REASON:-unknown}"
                log "  BVC2 kept: $orig_name"
                (( ++count_unsup )) || true
            fi
            CURRENT_TMP=""
            continue
        fi
        case "$vcodec" in
            h264|hevc|mpeg4) vcodec_args=("-c:v" "copy") ;;
            *)               vcodec_args=("-c:v" "libx264" "-preset" "fast" "-crf" "18" "-pix_fmt" "yuv420p") ;;
        esac

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
        # Safety net: never publish an output whose video codec is unknown/bvc2
        out_vc=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name \
                    -of csv=p=0 "$tmp_path" </dev/null 2>/dev/null | head -1)
        out_vt=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_tag_string \
                    -of csv=p=0 "$tmp_path" </dev/null 2>/dev/null | head -1)
        if [[ -z "$out_vc" || "$out_vc" == "none" || "$out_vc" == "unknown" || "$out_vt" == bvc* ]]; then
            vid_ok=0
        fi
        if (( out_size > 0 && vid_ok == 1 )) \
           && ffprobe -v error -i "$tmp_path" \
                  -show_entries format=duration -of csv=p=0 \
                  2>/dev/null | grep -q '[0-9]'; then
            touch -r "$src" "$tmp_path" 2>/dev/null || true   # keep original date => same gallery position
            mv -f "$tmp_path" "$target_path"
            rm -f "$src"
            queue_scan "$target_path"
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

log "Video normalization finished. Success: $count_ok, Fail: $count_fail, Skipped: $count_skip, bvc2 re-downloaded: $count_bvc2, bvc2 kept: $count_unsup"
printf "${C_GREEN}[✓] Summary: Videos OK=%d, Failed=%d, Skipped=%d, bvc2 redownloaded=%d, bvc2 kept=%d${C_RESET}\n" "$count_ok" "$count_fail" "$count_skip" "$count_bvc2" "$count_unsup"

# Re-downloaded H.264 copies were created mid-run: normalize them right now
if (( count_bvc2 > 0 )) && [[ -z "${NORMALIZE_PASS2:-}" ]]; then
    printf "${C_BLUE}[*] Second pass: normalizing re-downloaded H.264 copies...${C_RESET}\n"
    NORMALIZE_PASS2=1 MEDIA_SCAN_QUEUE="$SCAN_QUEUE" bash "${BASH_SOURCE[0]}" </dev/null
fi

if (( SCAN_OWNER == 1 )); then
    scan_queue "$SCAN_QUEUE"
    rm -f "$SCAN_QUEUE"
fi
