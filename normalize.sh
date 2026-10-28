#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  @file        normalize.sh
#  @brief       Video sanitizer, constant linear audio normalizer (-9 LUFS),
#               output integrity verifier, and Android MediaScanner trigger.
#  @author      Anna Morgrett (https://github.com/AnnaMorgrett/Termux)
#  @license     MIT
#  @version     3.0.0
#
#  Modes:
#    normalize.sh                      scan input folders (original behaviour)
#    normalize.sh --file PATH [--keep-original]
#                                      process ONE file (used by the queue worker)
#                                      exit: 0 ok, 1 failed, 2 no video, 3 unsupported, 64 invalid setting
#                                      env NORMALIZE_RESULT_FILE=path -> writes OUTPUT=<file>
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

# User settings written by the Web UI (data/config.conf). Real env vars still win.
_NORM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$_NORM_DIR/config_lib.sh" ]]; then
    # shellcheck source=config_lib.sh
    source "$_NORM_DIR/config_lib.sh"
    load_config "${PIPELINE_CONFIG:-$_NORM_DIR/data/config.conf}"
fi

readonly INPUT_DIRS=(
    "$SD/DCIM/TikTok"
    "$SD/Download/yt-dlp"
)
readonly VIDEO_OUT="$SD/Movies/NormalizedVideo"
readonly LOG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/media_processor_log.txt"

# NORM_MODE=peak (default): percentage scale. 0% = -9.0 dB peak ... 100% = -0.1 dB peak
#   Target_dB = -9 + 8.9 * (PEAK_PERCENT / 100). Constant gain so the audio PEAK lands exactly on it.
#   FORCED on every file with audio: no audio copy, no audio stripping, no skipping the filter.
# NORM_MODE=lufs: the older loudness mode (TARGET_LUFS + TRUE_PEAK_CEILING cap).
readonly NORM_MODE="${NORM_MODE:-peak}"
readonly PEAK_PERCENT="${PEAK_PERCENT:-100}"
readonly PEAK_TOLERANCE="${PEAK_TOLERANCE:-0.05}"          # dB: the OUTPUT's real peak must be 0..this far BELOW the target (the target is a ceiling)
readonly PEAK_FALLBACK_TOLERANCE="${PEAK_FALLBACK_TOLERANCE:-0.30}"   # dB: if AAC makes the 0..PEAK_TOLERANCE window impossible, accept the best try up to this far BELOW target (never above). 0 = strict only
readonly TARGET_LUFS="${TARGET_LUFS:--9}"
readonly TRUE_PEAK_CEILING="${TRUE_PEAK_CEILING:--1.0}"   # dBTP: gain is capped so peaks stay below this
readonly VERIFY_DECODE="${VERIFY_DECODE:-1}"              # 1 = also decode output AUDIO once (video: packets + duration)
readonly AUDIO_BITRATE="${AUDIO_BITRATE:-192k}"
readonly FFMPEG_LOGLEVEL="${FFMPEG_LOGLEVEL:-info}"
readonly TMP_DIR="$VIDEO_OUT/.tmp"                        # hidden + .nomedia: Gallery never sees half-written files

is_num() { [[ "$1" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; }
if ! is_num "$TARGET_LUFS" || ! is_num "$TRUE_PEAK_CEILING"; then
    echo "[FATAL] TARGET_LUFS and TRUE_PEAK_CEILING must be numbers" >&2
    exit 64
fi
if [[ "$NORM_MODE" != "peak" && "$NORM_MODE" != "lufs" ]]; then
    echo "[FATAL] NORM_MODE must be 'peak' or 'lufs' (got '$NORM_MODE')" >&2; exit 64
fi
if ! [[ "$PEAK_PERCENT" =~ ^[0-9]+(\.[0-9]+)?$ ]] || ! awk -v p="$PEAK_PERCENT" 'BEGIN{exit !(p>=0 && p<=100)}'; then
    echo "[FATAL] PEAK_PERCENT must be a number from 0 to 100 (got '$PEAK_PERCENT')" >&2; exit 64
fi
if ! [[ "$PEAK_TOLERANCE" =~ ^[0-9]+(\.[0-9]+)?$ ]] || ! awk -v t="$PEAK_TOLERANCE" 'BEGIN{exit !(t>=0.01 && t<=1)}'; then
    echo "[FATAL] PEAK_TOLERANCE must be 0.01 to 1 dB (got '$PEAK_TOLERANCE')" >&2; exit 64
fi
if ! [[ "$PEAK_FALLBACK_TOLERANCE" =~ ^[0-9]+(\.[0-9]+)?$ ]] || ! awk -v t="$PEAK_FALLBACK_TOLERANCE" 'BEGIN{exit !(t>=0 && t<=1)}'; then
    echo "[FATAL] PEAK_FALLBACK_TOLERANCE must be 0 to 1 dB (got '$PEAK_FALLBACK_TOLERANCE')" >&2; exit 64
fi
# Percentage -> dB, linear: 0% = -9.000, 50% = -4.550, 100% = -0.100
TARGET_PEAK_DB=$(awk -v p="$PEAK_PERCENT" 'BEGIN{printf "%.3f", -9 + 8.9 * (p / 100)}')
readonly TARGET_PEAK_DB

CURRENT_TMP=""
CURRENT_CAL=""
CAL_BITRATE=""
KEEP_ORIGINAL=0
SINGLE_FILE=""
REDL_OUT=""
REDL_REASON=""
LAST_OUTPUT=""
FF_PID=""

# ── Usage & Help ──────────────────────────────────────────────────────────────
show_help() {
    cat << H_EOF
Usage: normalize.sh [--file PATH [--keep-original]] [-h]

Audio normalization is applied to EVERY file that has audio (it cannot be skipped).
Default mode "peak": PEAK_PERCENT (0-100) sets the target audio peak linearly:
  0% = -9.0 dB   50% = -4.55 dB   100% = -0.1 dB      (Target_dB = -9 + 8.9 * percent/100)
Constant linear gain scales the audio so its peak lands on that target (no compression).
Current setting: ${PEAK_PERCENT}% = ${TARGET_PEAK_DB} dB, mode ${NORM_MODE}.
Mode "lufs" (NORM_MODE=lufs): constant gain to ${TARGET_LUFS} LUFS, capped at ${TRUE_PEAK_CEILING} dBTP.
Video is stream-copied when possible; re-encoded only as a verified last resort.
The original is deleted only after the output is verified and saved.

Without --file it scans:
  - $SD/DCIM/TikTok
  - $SD/Download/yt-dlp
Target Directory:
  - $VIDEO_OUT

Supported Formats:
  MP4, MKV, WEBM, MOV, AVI, 3GP, TS, FLV, M4V

Environment Overrides:
  NORM_MODE           peak (default) or lufs
  PEAK_PERCENT        0-100, target peak scale for mode peak (Default: 100)
  PEAK_TOLERANCE      accepted error of the output's real peak, in dB (Default: 0.05)
  PEAK_FALLBACK_TOLERANCE  if AAC makes that impossible, accept the best try up to this far
                      below target (never more than 0.10 dB above); 0 = strict only (Default: 0.30)
  TARGET_LUFS         Target loudness in LUFS (Default: -9)
  TRUE_PEAK_CEILING   Max true peak in dBTP after gain (Default: -1.0)
  VERIFY_DECODE       1 = decode output audio once as a check (Default: 1)
  AUDIO_BITRATE       Audio bitrate for normalized AAC stream (Default: 192k)
  FFMPEG_LOGLEVEL     ffmpeg log level written to the log (Default: info)
  MEDIA_DIR           Custom root media directory (Default: $SD)

Options:
  --file PATH         Process one file only (queue worker mode)
  --keep-original     Never delete the source file (shared local files)
  -h, --help          Display this documentation.
H_EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)       show_help; exit 0 ;;
        --file)          [[ $# -ge 2 ]] || { echo "[ERROR] --file needs a path" >&2; exit 2; }
                         SINGLE_FILE="$2"; shift 2 ;;
        --keep-original) KEEP_ORIGINAL=1; shift ;;
        *)               echo "[ERROR] Unknown option: $1" >&2; exit 2 ;;
    esac
done

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
    # verified (h264/hevc codec, packets present, audio decodes cleanly).
    local stem="$1" src="$2" id user url tmpd out vc ferr ytmsg pk
    REDL_REASON=""; REDL_OUT=""
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
    # Check: codec known, packets exist, audio decodes. (No full VIDEO decode:
    # some originals have harmless decode errors and must not be rejected.)
    vc=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name \
            -of csv=p=0 "$out" </dev/null 2>/dev/null | head -1)
    pk=$(count_vpackets "$out")
    ferr=$(audio_decode_errors "$out")
    if [[ "$vc" =~ ^(h264|hevc)$ ]] && [[ "$pk" =~ ^[0-9]+$ ]] && (( pk > 0 )) && [[ -z "$ferr" ]]; then
        touch -r "$src" "$out" 2>/dev/null || true
        if mv -f "$out" "$(dirname "$src")/${stem}_h264.mp4"; then
            REDL_OUT="$(dirname "$src")/${stem}_h264.mp4"
            rm -f "$src"
            rm -rf "$tmpd"
            log "  REDOWNLOAD OK ($vc): $stem -> ${stem}_h264.mp4; bvc2 original removed"
            return 0
        fi
        REDL_REASON="could not move downloaded file"
        rm -rf "$tmpd"; return 1
    fi
    REDL_REASON="downloaded file rejected (codec=${vc:-?}, packets=${pk:-?}${ferr:+, audio decode errors})"
    log "  REDOWNLOAD REJECTED (codec=${vc:-?} packets=${pk:-?} err=${ferr:-none}) for $stem"
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

# ── Probing helpers ───────────────────────────────────────────────────────────
kv() {  # kv "a=1|b=2" b  -> 2
    local s="|$1|" k="$2"
    [[ "$s" == *"|$k="* ]] || return 0
    s="${s#*|$k=}"
    printf '%s' "${s%%|*}"
}

# One ffprobe call -> V_COUNT V_CODEC V_TAG A_CODEC
probe_streams() {
    local line ct
    V_COUNT=0; V_CODEC=""; V_TAG=""; A_CODEC=""
    while IFS= read -r line; do
        ct=$(kv "$line" codec_type)
        case "$ct" in
            video)
                (( ++V_COUNT )) || true
                if (( V_COUNT == 1 )); then
                    V_CODEC=$(kv "$line" codec_name); V_TAG=$(kv "$line" codec_tag_string)
                fi ;;
            audio)
                [[ -z "$A_CODEC" ]] && A_CODEC=$(kv "$line" codec_name) ;;
        esac
    done < <(ffprobe -v error -show_entries stream=codec_type,codec_name,codec_tag_string \
                -of compact=p=0 "$1" </dev/null 2>/dev/null)
}

count_vpackets() {  # packets of first video stream (reads container, no decoding)
    ffprobe -v error -select_streams v:0 -count_packets -show_entries stream=nb_read_packets \
        -of csv=p=0 "$1" </dev/null 2>/dev/null | head -1 | tr -cd '0-9'   # mkv prints "100," -> keep digits only
}

video_duration() {  # video stream duration, falling back to container duration
    local d
    d=$(ffprobe -v error -select_streams v:0 -show_entries stream=duration \
            -of csv=p=0 "$1" </dev/null 2>/dev/null | head -1 | tr -cd '0-9.')
    is_num "$d" || d=$(ffprobe -v error -show_entries format=duration \
            -of csv=p=0 "$1" </dev/null 2>/dev/null | head -1 | tr -cd '0-9.')
    is_num "$d" && printf '%s' "$d"
}

audio_decode_errors() {  # prints up to 3 error lines (empty = clean)
    ffmpeg -v error -nostdin -i "$1" -map 0:a:0 -f null - </dev/null 2>&1 | head -3
}

# ── Loudness: constant linear gain with true-peak cap (NO compression/limiter) ─
# Sets: GAIN_DB, MEASURED_I, MEASURED_TP, GAIN_CAPPED(0/1)
compute_gain() {
    local src="$1" stats tp
    GAIN_DB="0.00"; GAIN_CAPPED=0
    # -vn + explicit audio map: measure audio only (no video decoding)
    stats=$(ffmpeg -hide_banner -nostdin -nostats -i "$src" -vn -map 0:a:0 \
                   -af loudnorm=print_format=json -f null - </dev/null 2>&1)
    MEASURED_I=$(printf '%s' "$stats" | grep '"input_i"' | head -1 | sed 's/.*: *"//;s/".*//')
    tp=$(printf '%s' "$stats" | grep '"input_tp"' | head -1 | sed 's/.*: *"//;s/".*//')
    MEASURED_TP="$tp"
    is_num "$MEASURED_I" || return 0            # silent/unmeasurable -> 0 dB
    if is_num "$tp"; then
        read -r GAIN_DB GAIN_CAPPED < <(awk -v t="$TARGET_LUFS" -v i="$MEASURED_I" -v tp="$tp" -v c="$TRUE_PEAK_CEILING" \
            'BEGIN { g=t-i; cap=0; if (tp+g > c) { g=c-tp; cap=1 } printf "%.2f %d\n", g, cap }')
    else
        GAIN_DB=$(awk -v t="$TARGET_LUFS" -v i="$MEASURED_I" 'BEGIN { printf "%.2f", t-i }')
    fi
}

# ── Peak mode: percentage target, constant gain, FORCED ──────────────────────
# Overall sample peak (dBFS) of the first audio stream: a number, "-inf" for digital silence, or empty if unreadable.
peak_db() {
    ffmpeg -hide_banner -nostdin -nostats -i "$1" -vn -map 0:a:0 -af astats=metadata=0:reset=0 -f null - </dev/null 2>&1 |
        awk '/Overall/ {o=1} o && /Peak level dB:/ {print $NF; exit}'
}

# Sets PEAK_SRC, PEAK_SILENT, GAIN_DB (3 decimals). Returns 1 if the audio cannot be measured.
compute_gain_peak() {
    PEAK_SRC=$(peak_db "$1"); PEAK_SILENT=0; GAIN_DB="0.000"; CAL_BITRATE=""
    if [[ "$PEAK_SRC" == "-inf" ]]; then PEAK_SILENT=1; return 0; fi
    is_num "$PEAK_SRC" || return 1
    GAIN_DB=$(awk -v t="$TARGET_PEAK_DB" -v p="$PEAK_SRC" 'BEGIN{printf "%.3f", t - p}')
}

# AAC is lossy, so the DECODED peak does not follow "source peak + gain" exactly (it jitters by a few tenths of a dB,
# especially near full scale). So: trial-encode ONLY the audio (small, cheap), measure the decoded result, and search for
# a gain whose real output peak is within PEAK_TOLERANCE of the target:
#   1) secant steps (gain += error) for the first trials, 2) small steps around the best gain found,
#   3) still no hit -> same search at a higher AAC bitrate (256k, then 320k: less codec noise).
# If the strict window is impossible, the best try inside the fallback window is used and flagged APPROXIMATE.
# The gain is ALWAYS applied; nothing here can skip or bypass the filter.
# Sets GAIN_DB, CAL_BITRATE, CAL_PEAK and the accepted error window PEAK_ERR_LO..PEAK_ERR_HI (error = target - peak).
# Returns 1 only if nothing inside even the fallback window was found.
calibrate_peak() {
    local src="$1" cal="$TMP_DIR/.cal.$$.mp4" br k rc pk err derr aerr g best_g="$GAIN_DB" bbest bbest_g i tries=0
    local fb_err=999 fb_g="" fb_br="" fb_pk="" fb_e=""
    local -a brs=("$AUDIO_BITRATE") offs=(0.03 -0.03 0.06 -0.06 0.10 -0.10 0.15)
    for i in 256k 320k; do awk -v a="${AUDIO_BITRATE%k}" -v b="${i%k}" 'BEGIN{exit !(b>a)}' && brs+=("$i"); done
    # The target is a CEILING: the output peak must never be above it. Accepted: 0 .. PEAK_TOLERANCE dB BELOW target
    # (error = target - peak, so 0 <= error <= tol). We aim at the middle of that window.
    local half; half=$(awk -v t="$PEAK_TOLERANCE" 'BEGIN{printf "%.4f", t/2}')
    best_g=$(awk -v g="$GAIN_DB" -v h="$half" 'BEGIN{printf "%.3f", g - h}')
    PEAK_ERR_LO="-0.001"; PEAK_ERR_HI="$PEAK_TOLERANCE"
    CURRENT_CAL="$cal"
    for br in "${brs[@]}"; do
        g="$best_g"; bbest=999; bbest_g="$g"; k=0
        while (( k < 8 )); do
            (( ++k, ++tries ))
            rm -f "$cal"
            ffmpeg -hide_banner -nostdin -nostats -loglevel "$FFMPEG_LOGLEVEL" -y -i "$src" -vn -map 0:a:0 \
                   -af "volume=${g}dB" -c:a aac -b:a "$br" -f mp4 "$cal" </dev/null 2>>"$LOG" &
            FF_PID=$!; wait "$FF_PID"; rc=$?; FF_PID=""
            if (( rc != 0 )); then log "  CALIBRATE: audio trial encode failed (gain ${g} dB, ${br})"; rm -f "$cal"; CURRENT_CAL=""; return 1; fi
            pk=$(peak_db "$cal")
            if ! is_num "$pk"; then log "  CALIBRATE: cannot measure the encoded peak ('$pk')"; rm -f "$cal"; CURRENT_CAL=""; return 1; fi
            err=$(awk -v t="$TARGET_PEAK_DB" -v p="$pk" 'BEGIN{printf "%.3f", t - p}')
            derr=$(awk -v e="$err" -v h="$half" 'BEGIN{printf "%.3f", e - h}')            # distance to the aim point
            aerr=$(awk -v e="$derr" 'BEGIN{printf "%.3f", (e<0)?-e:e}')
            log "  CALIBRATE #${tries} (${br}): gain ${g} dB -> decoded peak ${pk} dB (target ${TARGET_PEAK_DB} dB, error ${err} dB)"
            if awk -v e="$err" -v tol="$PEAK_TOLERANCE" 'BEGIN{exit !(e>=-0.001 && e<=tol)}'; then
                GAIN_DB="$g"; CAL_BITRATE="$br"; CAL_PEAK="$pk"; rm -f "$cal"; CURRENT_CAL=""; return 0
            fi
            # best fallback candidate: NEVER above the target, at most PEAK_FALLBACK_TOLERANCE below it (closest wins)
            if awk -v e="$err" -v f="$PEAK_FALLBACK_TOLERANCE" -v b="$fb_err" 'BEGIN{exit !(f>0 && e>=-0.001 && e<=f && e<b)}'; then
                fb_err="$err"; fb_g="$g"; fb_br="$br"; fb_pk="$pk"; fb_e="$err"
            fi
            if awk -v e="$aerr" -v b="$bbest" 'BEGIN{exit !(e<b)}'; then bbest="$aerr"; bbest_g="$g"; fi
            if (( k <= 3 )); then g=$(awk -v g="$g" -v e="$derr" 'BEGIN{printf "%.3f", g + e}')
            else g=$(awk -v g="$bbest_g" -v o="${offs[$(( (k - 4) % ${#offs[@]} ))]}" 'BEGIN{printf "%.3f", g + o}'); fi
        done
        best_g="$bbest_g"
        log "  CALIBRATE: ${br} could not reach the target within ${PEAK_TOLERANCE} dB (best error ${bbest} dB)"
        [[ -n "$fb_g" && "$br" != "${brs[0]}" ]] && break          # a usable fallback exists and a higher bitrate was tried: stop
    done
    rm -f "$cal"; CURRENT_CAL=""
    if [[ -n "$fb_g" ]]; then
        GAIN_DB="$fb_g"; CAL_BITRATE="$fb_br"; CAL_PEAK="$fb_pk"
        PEAK_ERR_LO="-0.001"; PEAK_ERR_HI="$PEAK_FALLBACK_TOLERANCE"
        log "  APPROXIMATE: AAC cannot hit ${TARGET_PEAK_DB} dB within ${PEAK_TOLERANCE} dB for this audio; using the best try (peak ${fb_pk} dB, error ${fb_e} dB, ${fb_br})"
        printf "  ${C_YELLOW}[Audio] APPROXIMATE:${C_RESET} best reachable peak %s dB (target %s dB, error %s dB)\n" "$fb_pk" "$TARGET_PEAK_DB" "$fb_e"
        return 0
    fi
    return 1
}

# ── Rendering & verification ──────────────────────────────────────────────────
# run_ffmpeg SRC TMP VMODE AMODE GAIN   (VMODE copy|enc, AMODE gain|acopy|none)
run_ffmpeg() {
    local src="$1" tmp="$2" vmode="$3" amode="$4" gain="$5"
    local -a va aa
    case "$vmode" in
        copy) va=(-c:v copy) ;;
        *)    va=(-c:v libx264 -preset fast -crf 18 -pix_fmt yuv420p -fps_mode passthrough) ;;
    esac
    case "$amode" in
        gain)  aa=(-map 0:a:0 -af "volume=${gain}dB" -c:a aac -b:a "${CAL_BITRATE:-$AUDIO_BITRATE}") ;;
        acopy) aa=(-map 0:a:0 -c:a copy) ;;
        *)     aa=(-an) ;;
    esac
    # Run as a tracked child so a kill/TERM of this script stops ffmpeg immediately.
    ffmpeg -hide_banner -nostdin -nostats -loglevel "$FFMPEG_LOGLEVEL" -y \
        -i "$src" -map 0:v:0 "${va[@]}" "${aa[@]}" \
        -movflags +faststart -f mp4 "$tmp" </dev/null 2>>"$LOG" &
    FF_PID=$!
    wait "$FF_PID"; local rc=$?
    FF_PID=""
    return "$rc"
}

# verify_output SRC OUT EXPECT_AUDIO(0/1) SRC_PACKETS SRC_DURATION VMODE
# Returns 0 only if the output is a complete, playable file. Reason in VERIFY_WHY.
verify_output() {
    local src="$1" out="$2" want_audio="$3" src_pk="$4" src_dur="$5" vmode="$6"
    local o_pk o_dur diff tol errs
    VERIFY_WHY=""
    [[ -s "$out" ]] || { VERIFY_WHY="empty output"; return 1; }
    probe_streams "$out"
    if [[ -z "$V_CODEC" || "$V_CODEC" == "none" || "$V_CODEC" == "unknown" || "$V_TAG" == bvc* ]]; then
        VERIFY_WHY="output video codec unknown"; return 1
    fi
    if (( want_audio == 1 )) && [[ -z "$A_CODEC" ]]; then VERIFY_WHY="output has no audio"; return 1; fi
    if (( want_audio == 0 )) && [[ -n "$A_CODEC" ]];  then VERIFY_WHY="unexpected audio in output"; return 1; fi
    o_pk=$(count_vpackets "$out")
    if [[ "$o_pk" =~ ^[0-9]+$ && "$src_pk" =~ ^[0-9]+$ ]]; then
        if [[ "$vmode" == "copy" ]]; then tol=0; else tol=$(( src_pk / 100 + 2 )); fi
        diff=$(( o_pk > src_pk ? o_pk - src_pk : src_pk - o_pk ))
        (( diff <= tol )) || { VERIFY_WHY="video packets $o_pk vs source $src_pk"; return 1; }
    else
        VERIFY_WHY="cannot count video packets"; return 1
    fi
    o_dur=$(video_duration "$out")
    [[ -n "$o_dur" ]] || { VERIFY_WHY="no duration"; return 1; }
    if [[ -n "$src_dur" ]]; then
        if ! awk -v a="$o_dur" -v b="$src_dur" 'BEGIN { d=a-b; if (d<0) d=-d; t=b*0.02; if (t<0.5) t=0.5; exit !(d<=t) }'; then
            VERIFY_WHY="duration $o_dur vs source $src_dur"; return 1
        fi
    fi
    if (( want_audio == 1 )) && [[ "$NORM_MODE" == "peak" && "${PEAK_SILENT:-0}" == "0" ]]; then
        local opk oerr
        opk=$(peak_db "$out")
        if ! is_num "$opk"; then VERIFY_WHY="cannot measure output peak"; return 1; fi
        oerr=$(awk -v t="$TARGET_PEAK_DB" -v p="$opk" 'BEGIN{printf "%.3f", t - p}')
        log "  OUTPUT PEAK: ${opk} dB (target ${TARGET_PEAK_DB} dB, error ${oerr} dB; accepted ${PEAK_ERR_LO}..${PEAK_ERR_HI})"
        awk -v e="$oerr" -v lo="${PEAK_ERR_LO:--0.001}" -v hi="${PEAK_ERR_HI:-0.05}" 'BEGIN{exit !(e>=lo && e<=hi)}' ||
            { VERIFY_WHY="output peak ${opk} dB is outside the accepted window around target ${TARGET_PEAK_DB} dB"; return 1; }
    fi
    if (( want_audio == 1 )) && [[ "$VERIFY_DECODE" == "1" ]]; then
        errs=$(audio_decode_errors "$out")
        if [[ -n "$errs" ]]; then
            # Source audio equally broken -> nothing better is possible; accept.
            if [[ -n "$(audio_decode_errors "$src")" ]]; then
                log "  NOTE: source audio has decode errors too; accepting output"
            else
                VERIFY_WHY="output audio decode errors"; return 1
            fi
        fi
    fi
    return 0
}

# ── Process ONE file. Return: 0 ok, 1 failed, 2 no video, 3 unsupported, 4 bvc2 replaced
process_file() {
    local src="$1" orig_name clean_name target_path tmp_path
    local vstreams vcodec vtag acodec src_pk src_dur vprimary a1 attempt vmode amode out_size
    local -a ladder=()
    LAST_OUTPUT=""
    orig_name=$(basename "$src")
    clean_name=$(sanitize_name "$orig_name")
    target_path=$(get_unique_dest "$VIDEO_OUT" "$clean_name")
    tmp_path="$TMP_DIR/${clean_name%.mp4}.$$.tmp.mp4"
    CURRENT_TMP="$tmp_path"

    printf "${C_CYAN}[*] Processing:${C_RESET} %s\n" "$orig_name"
    log "Processing video: $orig_name"

    # ── 1. Probe (one ffprobe call) ───────────────────────────────────────
    probe_streams "$src"
    vstreams=$V_COUNT; vcodec=$V_CODEC; vtag=$V_TAG; acodec=$A_CODEC

    if (( vstreams == 0 )); then
        printf "  ${C_YELLOW}[SKIP] No video stream detected.${C_RESET}\n"
        log "  SKIPPED: No video stream detected in $orig_name"
        CURRENT_TMP=""; return 2
    fi

    if [[ -z "$vcodec" || "$vcodec" == "none" || "$vcodec" == "unknown" || "$vtag" == bvc* ]]; then
        CURRENT_TMP=""
        if [[ -n "${NORMALIZE_PASS2:-}" || "$KEEP_ORIGINAL" == "1" ]]; then return 3; fi
        printf "  ${C_YELLOW}[bvc2] ByteVC2 video - not playable by most players.${C_RESET}\n"
        if redownload_h264 "${orig_name%.*}" "$src"; then
            printf "  ${C_GREEN}[✓] Replaced with verified H.264 copy; normalizing it now.${C_RESET}\n"
            NORMALIZE_PASS2=1 process_file "$REDL_OUT"
            local rc=$?
            (( rc == 0 )) && return 4
            return "$rc"
        fi
        printf "  ${C_YELLOW}[!] Could not get an H.264 copy (%s). Original kept untouched.${C_RESET}\n" "${REDL_REASON:-unknown}"
        log "  BVC2 kept: $orig_name"
        return 3
    fi

    case "$vcodec" in
        h264|hevc|mpeg4) vprimary="copy" ;;
        *)               vprimary="enc"  ;;
    esac

    # ── 2. Audio: constant linear gain (peak percentage mode, or LUFS mode) ─
    a1="none"
    if [[ -n "$acodec" && "$NORM_MODE" == "peak" ]]; then
        # FORCED: every file with audio goes through the volume filter. If the audio cannot be measured or the
        # target cannot be reached, the file FAILS and the original is kept - it is never saved un-normalized.
        if ! compute_gain_peak "$src"; then
            printf "  ${C_RED}[ERROR] Audio could not be measured. Not saving an un-normalized file; original kept.${C_RESET}\n" >&2
            log "  ERROR: audio peak could not be measured for $orig_name; original preserved (normalization is mandatory)"
            CURRENT_TMP=""; return 1
        fi
        if (( PEAK_SILENT == 1 )); then
            printf "  ${C_YELLOW}[Audio] Digital silence: nothing to scale; filter still applied (0 dB).${C_RESET}\n"
            log "  PEAK: audio is digital silence; volume filter applied at 0 dB"
        else
            if ! calibrate_peak "$src"; then
                printf "  ${C_RED}[ERROR] Could not reach the target peak (%s dB). Original kept.${C_RESET}\n" "$TARGET_PEAK_DB" >&2
                log "  ERROR: target peak ${TARGET_PEAK_DB} dB not reachable for $orig_name; original preserved"
                CURRENT_TMP=""; return 1
            fi
            awk -v g="$GAIN_DB" 'BEGIN{exit !(g>40 || g<-40)}' && log "  WARNING: very large gain (${GAIN_DB} dB) - the source audio is extremely quiet or loud"
        fi
        printf "  ${C_BLUE}[Audio] Peak:${C_RESET} %s dB -> target %s dB (%s%%) -> ${C_BLUE}Linear Gain:${C_RESET} %s dB\n" \
               "$PEAK_SRC" "$TARGET_PEAK_DB" "$PEAK_PERCENT" "$GAIN_DB"
        log "  PEAK: ${PEAK_SRC} dB -> target ${TARGET_PEAK_DB} dB (${PEAK_PERCENT}%) -> Applying Constant Linear Gain: ${GAIN_DB} dB"
        a1="gain"
    elif [[ -n "$acodec" ]]; then
        compute_gain "$src"
        if (( GAIN_CAPPED == 1 )); then
            printf "  ${C_YELLOW}[Audio] PEAK CAP:${C_RESET} gain limited to keep true peak <= %s dBTP\n" "$TRUE_PEAK_CEILING"
            log "  PEAK CAP: wanted $(awk -v t="$TARGET_LUFS" -v i="$MEASURED_I" 'BEGIN{printf "%.2f", t-i}') dB, using ${GAIN_DB} dB (true peak ${MEASURED_TP} dBTP, ceiling ${TRUE_PEAK_CEILING})"
        fi
        printf "  ${C_BLUE}[Audio] Measured:${C_RESET} %s LUFS -> ${C_BLUE}Linear Gain:${C_RESET} %s dB (Target: %s LUFS)\n" \
               "${MEASURED_I:-N/A}" "$GAIN_DB" "$TARGET_LUFS"
        log "  LUFS: ${MEASURED_I:-N/A} -> Applying Constant Linear Gain: ${GAIN_DB} dB"
        a1="gain"
        if [[ "$GAIN_DB" == "0.00" && "$acodec" == "aac" ]]; then
            a1="acopy"; log "  Gain is 0 dB and audio is AAC: copying audio (no re-encode)"
        fi
    else
        printf "  ${C_YELLOW}[Audio] Stream absent; remuxing video only (nothing to normalize).${C_RESET}\n"
        log "  No audio stream detected; remuxing video only"
    fi

    # ── 3. Attempt ladder: first VERIFIED result wins ─────────────────────
    if [[ -z "$acodec" ]]; then
        ladder=("${vprimary}:none"); [[ "$vprimary" == "copy" ]] && ladder+=("enc:none")
    elif [[ "$NORM_MODE" == "peak" ]]; then
        # only attempts that APPLY the gain: video may fall back to a re-encode, audio never bypasses the filter
        if [[ "$vprimary" == "copy" ]]; then ladder=("copy:gain" "enc:gain"); else ladder=("enc:gain"); fi
    elif [[ "$vprimary" == "copy" ]]; then
        ladder=("copy:$a1")
        [[ "$a1" != "acopy" ]] && ladder+=("copy:acopy")
        ladder+=("enc:$a1")
        [[ "$a1" != "acopy" ]] && ladder+=("enc:acopy")
        ladder+=("copy:none" "enc:none")
    else
        ladder=("enc:$a1")
        [[ "$a1" != "acopy" ]] && ladder+=("enc:acopy")
        ladder+=("enc:none")
    fi

    src_pk=$(count_vpackets "$src")
    src_dur=$(video_duration "$src")

    for attempt in "${ladder[@]}"; do
        vmode="${attempt%%:*}"; amode="${attempt##*:}"
        rm -f "$tmp_path"
        if [[ "$attempt" != "${ladder[0]}" ]]; then
            printf "  ${C_YELLOW}[!] Fallback: video=%s audio=%s${C_RESET}\n" "$vmode" "$amode"
        fi
        log "  ATTEMPT video=$vmode audio=$amode"
        if ! run_ffmpeg "$src" "$tmp_path" "$vmode" "$amode" "${GAIN_DB:-0.00}"; then
            log "  ATTEMPT failed (ffmpeg error): video=$vmode audio=$amode"
            continue
        fi
        local want_audio=1; [[ "$amode" == "none" ]] && want_audio=0
        if verify_output "$src" "$tmp_path" "$want_audio" "$src_pk" "$src_dur" "$vmode"; then
            out_size=$(wc -c < "$tmp_path" 2>/dev/null || echo 0)
            touch -r "$src" "$tmp_path" 2>/dev/null || true   # keep original date => same gallery position
            if mv -f "$tmp_path" "$target_path"; then
                [[ "$KEEP_ORIGINAL" == "1" ]] || rm -f "$src"
                queue_scan "$target_path"
                LAST_OUTPUT="$target_path"
                printf "  ${C_GREEN}[✓] Verified & Saved:${C_RESET} %s (%s bytes)\n" "$(basename "$target_path")" "$out_size"
                log "  SUCCESS: $orig_name -> $(basename "$target_path") [${out_size} bytes] (video=$vmode audio=$amode)"
                CURRENT_TMP=""; return 0
            fi
            log "  ERROR: could not move output into place; source preserved"
            break
        fi
        log "  ATTEMPT rejected by verification (video=$vmode audio=$amode): $VERIFY_WHY"
    done

    rm -f "$tmp_path"
    printf "  ${C_RED}[ERROR] All attempts failed. Source file preserved.${C_RESET}\n" >&2
    log "  ERROR: all attempts failed for $orig_name. Source preserved."
    CURRENT_TMP=""; return 1
}

# ── Cleanup Handler ───────────────────────────────────────────────────────────
on_interrupt() {
    [[ -n "$FF_PID" ]] && kill "$FF_PID" 2>/dev/null && wait "$FF_PID" 2>/dev/null
    [[ -n "$CURRENT_TMP" && -f "$CURRENT_TMP" ]] && rm -f "$CURRENT_TMP"
    [[ -n "$CURRENT_CAL" && -f "$CURRENT_CAL" ]] && rm -f "$CURRENT_CAL"
    log "Video processing interrupted"
    exit 130
}
trap on_interrupt INT TERM HUP

# ── Execution ─────────────────────────────────────────────────────────────────
mkdir -p "$VIDEO_OUT" "$TMP_DIR" "$(dirname "$LOG")"
: > "$TMP_DIR/.nomedia" 2>/dev/null || true
find "$TMP_DIR" -maxdepth 1 -type f \( -name '*.tmp.mp4' -o -name '.cal.*' \) -mmin +60 -delete 2>/dev/null || true   # orphans of killed runs

# ── Single-file mode (queue worker) ───────────────────────────────────────────
if [[ -n "$SINGLE_FILE" ]]; then
    if [[ ! -f "$SINGLE_FILE" ]]; then
        echo "[ERROR] File not found: $SINGLE_FILE" >&2; exit 1
    fi
    process_file "$SINGLE_FILE"; rc=$?
    [[ -n "$LAST_OUTPUT" ]] && printf 'OUTPUT=%s\n' "$LAST_OUTPUT"
    [[ -n "${NORMALIZE_RESULT_FILE:-}" ]] && printf 'OUTPUT=%s\n' "$LAST_OUTPUT" > "$NORMALIZE_RESULT_FILE"
    (( rc == 4 )) && rc=0
    if (( SCAN_OWNER == 1 )); then scan_queue "$SCAN_QUEUE"; rm -f "$SCAN_QUEUE"; fi
    exit "$rc"
fi

# ── Scan mode (original behaviour) ────────────────────────────────────────────
log "Beginning video normalization stage..."
printf "${C_BLUE}[*] Scanning for pending videos... (normalize.sh v3.0.0)${C_RESET}\n"

count_ok=0; count_fail=0; count_skip=0; count_bvc2=0; count_unsup=0

for dir in "${INPUT_DIRS[@]}"; do
    [[ -d "$dir" ]] || continue
    while IFS= read -r -d '' src <&3; do
        [[ -f "$src" ]] || continue            # may have been replaced/removed meanwhile
        # file still being written? wait until it is at least 5 s old
        age=$(( $(date +%s) - $(stat -c %Y "$src" 2>/dev/null || echo 0) ))
        (( age >= 0 && age < 5 )) && sleep $(( 5 - age ))
        process_file "$src"
        case $? in
            0) (( ++count_ok ))    || true ;;
            1) (( ++count_fail ))  || true ;;
            2) (( ++count_skip ))  || true ;;
            3) (( ++count_unsup )) || true ;;
            4) (( ++count_ok ))    || true; (( ++count_bvc2 )) || true ;;
        esac
        CURRENT_TMP=""
    done 3< <(find "$dir" -maxdepth 1 -type f \( \
                 -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.webm' \
              -o -iname '*.mov' -o -iname '*.avi' -o -iname '*.3gp'  \
              -o -iname '*.ts'  -o -iname '*.flv' -o -iname '*.m4v'  \
             \) ! -regex '.*\.f[0-9]+\.[A-Za-z0-9]+$' -print0 2>/dev/null)   # skip yt-dlp format fragments
done

log "Video normalization finished. Success: $count_ok, Fail: $count_fail, Skipped: $count_skip, bvc2 re-downloaded: $count_bvc2, bvc2 kept: $count_unsup"
printf "${C_GREEN}[✓] Summary: Videos OK=%d, Failed=%d, Skipped=%d, bvc2 redownloaded=%d, bvc2 kept=%d${C_RESET}\n" "$count_ok" "$count_fail" "$count_skip" "$count_bvc2" "$count_unsup"

if (( SCAN_OWNER == 1 )); then
    scan_queue "$SCAN_QUEUE"
    rm -f "$SCAN_QUEUE"
fi
