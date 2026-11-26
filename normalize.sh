#!/usr/bin/env bash
# normalize.sh - Video sanitizer, constant linear audio normalizer, and integrity verifier.
set -u

if [[ -t 1 ]]; then
    C_BLUE='\033[0;34m' C_GREEN='\033[0;32m' C_YELLOW='\033[0;33m' C_RED='\033[0;31m' C_CYAN='\033[0;36m' C_RESET='\033[0m'
else
    C_BLUE='' C_GREEN='' C_YELLOW='' C_RED='' C_CYAN='' C_RESET=''
fi

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SD="${MEDIA_DIR:-/storage/emulated/0}"
readonly BVC2_BIN="${PREFIX:-/data/data/com.termux/files/usr}/opt/ffmpeg-bvc2/bin"
[[ -x "$BVC2_BIN/ffmpeg" && -x "$BVC2_BIN/ffprobe" ]] && export PATH="$BVC2_BIN:$PATH"

# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"
load_config "${PIPELINE_CONFIG:-$SCRIPT_DIR/data/config.conf}"

readonly INPUT_DIRS=(
    "$SD/DCIM/TikTok"
    "$SD/Download/yt-dlp"
)
readonly VIDEO_OUT="$SD/Movies/NormalizedVideo"
readonly TMP_DIR="$VIDEO_OUT/.tmp"
readonly LOG="$SCRIPT_DIR/media_processor_log.txt"

readonly NORM_MODE="${NORM_MODE:-peak}"
readonly PEAK_PERCENT="${PEAK_PERCENT:-100}"
readonly PEAK_TOLERANCE="${PEAK_TOLERANCE:-0.05}"
readonly PEAK_FALLBACK_TOLERANCE="${PEAK_FALLBACK_TOLERANCE:-0.30}"
readonly TARGET_LUFS="${TARGET_LUFS:--9}"
readonly TRUE_PEAK_CEILING="${TRUE_PEAK_CEILING:--1.0}"
readonly VERIFY_DECODE="${VERIFY_DECODE:-1}"
readonly AUDIO_BITRATE="${AUDIO_BITRATE:-192k}"
readonly FFMPEG_LOGLEVEL="${FFMPEG_LOGLEVEL:-info}"

is_num() { [[ "$1" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; }

for key in NORM_MODE PEAK_PERCENT PEAK_TOLERANCE PEAK_FALLBACK_TOLERANCE TARGET_LUFS TRUE_PEAK_CEILING VERIFY_DECODE AUDIO_BITRATE FFMPEG_LOGLEVEL; do
    if ! validate_config_kv "$key" "${!key}"; then
        echo "[FATAL] Invalid config $key='${!key}'" >&2
        exit 64
    fi
done

TARGET_PEAK_DB=$(awk -v p="$PEAK_PERCENT" 'BEGIN{printf "%.3f", -9 + 8.0 * (p / 100)}')
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

show_help() {
    cat << EOF
Usage: normalize.sh [--file PATH [--keep-original]] [-h]

Normalizes audio with constant linear gain (no dynamic compression) and ensures
Android-compatible MP4 container/codec parameters.
Current target: ${PEAK_PERCENT}% = ${TARGET_PEAK_DB} dBFS (mode: ${NORM_MODE}).
EOF
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

log() { printf '[%s] [NORMALIZE] %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

if [[ -n "${MEDIA_SCAN_QUEUE:-}" ]]; then
    SCAN_QUEUE="$MEDIA_SCAN_QUEUE"; SCAN_OWNER=0
else
    SCAN_QUEUE="$(mktemp)"; SCAN_OWNER=1
fi
queue_scan() { printf '%s\n' "$1" >> "$SCAN_QUEUE"; }
# shellcheck source=media_scan.sh
source "$SCRIPT_DIR/media_scan.sh"

sanitize_name() {
    local raw_base="${1%.*}" clean
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

kv() {
    local s="|$1|" k="$2"
    [[ "$s" == *"|$k="* ]] || return 0
    s="${s#*|$k=}"
    printf '%s' "${s%%|*}"
}

probe_streams() {
    local line ct
    V_COUNT=0; V_CODEC=""; V_TAG=""; V_PIX_FMT=""; A_CODEC=""; A_CHANNELS=""
    while IFS= read -r line; do
        ct=$(kv "$line" codec_type)
        case "$ct" in
            video)
                (( ++V_COUNT )) || true
                if (( V_COUNT == 1 )); then
                    V_CODEC=$(kv "$line" codec_name)
                    V_TAG=$(kv "$line" codec_tag_string)
                    V_PIX_FMT=$(kv "$line" pix_fmt)
                fi
                ;;
            audio)
                if [[ -z "$A_CODEC" ]]; then
                    A_CODEC=$(kv "$line" codec_name)
                    A_CHANNELS=$(kv "$line" channels | tr -cd '0-9')
                fi
                ;;
        esac
    done < <(ffprobe -v error -show_entries stream=codec_type,codec_name,codec_tag_string,pix_fmt,channels \
                -of compact=p=0 "$1" </dev/null 2>/dev/null)
}

count_vpackets() {
    ffprobe -v error -select_streams v:0 -count_packets -show_entries stream=nb_read_packets \
        -of csv=p=0 "$1" </dev/null 2>/dev/null | head -1 | tr -cd '0-9'
}

video_duration() {
    local d
    d=$(ffprobe -v error -select_streams v:0 -show_entries stream=duration \
            -of csv=p=0 "$1" </dev/null 2>/dev/null | head -1 | tr -cd '0-9.')
    is_num "$d" || d=$(ffprobe -v error -show_entries format=duration \
            -of csv=p=0 "$1" </dev/null 2>/dev/null | head -1 | tr -cd '0-9.')
    is_num "$d" && printf '%s' "$d"
}

audio_decode_errors() {
    ffmpeg -v error -nostdin -i "$1" -map 0:a:0 -f null - </dev/null 2>&1 | head -3
}

video_stream_errors() {
    ffmpeg -v error -nostdin -err_detect explode -i "$1" -map 0:v:0 -c copy -f null - </dev/null 2>&1 | head -3
}

redownload_h264() {
    local stem="$1" src="$2" id user url tmpd out vc pk ferr ytmsg attempt
    REDL_REASON=""; REDL_OUT=""
    if [[ "$stem" =~ ^(.+)_[0-9]{4}-[0-9]{2}-[0-9]{2}_([0-9]{15,})([[:space:]]*\([0-9]+\))?$ ]]; then
        user="${BASH_REMATCH[1]}"; id="${BASH_REMATCH[2]}"
    else
        REDL_REASON="filename has no user/date/ID pattern"; return 1
    fi
    command -v yt-dlp &>/dev/null || { REDL_REASON="yt-dlp not found"; return 1; }
    url="https://www.tiktok.com/@${user}/video/${id}"
    tmpd=$(mktemp -d "$SD/Download/.redl.XXXXXX") || return 1
    printf "  ${C_BLUE}[~] Re-downloading as H.264:${C_RESET} %s\n" "$url"
    log "  REDOWNLOAD: $url"

    for attempt in 1 2; do
        yt-dlp --no-mtime -S "vcodec:h264,res,acodec:m4a" \
               -f "b[vcodec^=h264][format_id!=download]/b[vcodec~='^(h265|hevc)'][format_id!=download]" \
               -o "$tmpd/%(id)s.%(ext)s" "$url" </dev/null > "$tmpd/yt.log" 2>&1
        cat "$tmpd/yt.log" >> "$LOG" 2>/dev/null
        out=$(find "$tmpd" -maxdepth 1 -type f -name '*.mp4' | head -1)
        [[ -n "$out" ]] && break
        (( attempt == 1 )) && sleep 3
    done

    if [[ -z "$out" ]]; then
        ytmsg=$(grep -E "ERROR|WARNING" "$tmpd/yt.log" | tail -1 | cut -c1-160)
        REDL_REASON="yt-dlp: ${ytmsg:-no output}"
        rm -rf "$tmpd"; return 1
    fi

    vc=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$out" </dev/null 2>/dev/null | head -1)
    pk=$(count_vpackets "$out")
    ferr=$(audio_decode_errors "$out")
    if [[ "$vc" =~ ^(h264|hevc)$ ]] && [[ "$pk" =~ ^[0-9]+$ ]] && (( pk > 0 )) && [[ -z "$ferr" ]]; then
        touch -r "$src" "$out" 2>/dev/null || true
        if mv -f "$out" "$(dirname "$src")/${stem}_h264.mp4"; then
            REDL_OUT="$(dirname "$src")/${stem}_h264.mp4"
            rm -f "$src"
            queue_scan "$src"
            rm -rf "$tmpd"
            log "  REDOWNLOAD OK ($vc): $stem -> ${stem}_h264.mp4"
            return 0
        fi
        REDL_REASON="could not move downloaded file"
    else
        REDL_REASON="downloaded file rejected (codec=${vc:-?}, packets=${pk:-?})"
    fi
    rm -rf "$tmpd"; return 1
}

_mean_vol() {
    ffmpeg -hide_banner -nostdin -nostats -i "$1" -vn -map 0:a:0 -af "${2}volumedetect" -f null - </dev/null 2>&1 \
        | awk '/mean_volume:/ {print $(NF-1); exit}'
}

audio_is_noise_only() {
    local sd full low
    NOISE_WHY=""
    sd=$(ffmpeg -hide_banner -nostdin -nostats -v quiet -i "$1" -vn -map 0:a:0 \
        -af "asetnsamples=n=4096:p=0,astats=metadata=1:reset=1,ametadata=print:key=lavfi.astats.Overall.RMS_level:file=-" \
        -f null - </dev/null 2>/dev/null |
        awk -F= '/RMS_level=/ && $2 !~ /inf/ {v=$2+0; n++; s+=v; q+=v*v}
                 END { if (n < 5) exit; m=s/n; d=q/n-m*m; if (d<0) d=0; printf "%.2f", sqrt(d) }')
    if is_num "$sd" && awk -v s="$sd" -v t="${NOISE_VAR_DB:-1.0}" 'BEGIN{exit !(s < t)}'; then
        NOISE_WHY="steady level (variation ${sd} dB)"; return 0
    fi
    full=$(_mean_vol "$1"); low=$(_mean_vol "$1" "lowpass=f=4000,")
    if is_num "$full" && is_num "$low" && awk -v f="$full" -v l="$low" -v g="${NOISE_BAND_GAP_DB:-25}" 'BEGIN{exit !(f - l > g)}'; then
        NOISE_WHY="no energy below 4 kHz (full ${full} dB, low ${low} dB)"; return 0
    fi
    return 1
}

compute_gain_lufs() {
    local src="$1" stats tp
    GAIN_DB="0.00"; GAIN_CAPPED=0
    stats=$(ffmpeg -hide_banner -nostdin -nostats -i "$src" -vn -map 0:a:0 -af loudnorm=print_format=json -f null - </dev/null 2>&1)
    MEASURED_I=$(printf '%s' "$stats" | grep '"input_i"' | head -1 | sed 's/.*: *"//;s/".*//')
    tp=$(printf '%s' "$stats" | grep '"input_tp"' | head -1 | sed 's/.*: *"//;s/".*//')
    MEASURED_TP="$tp"
    awk -v i="$MEASURED_I" -v f="${SILENCE_FLOOR_DB:--60}" 'BEGIN{exit !(i < f)}' && return 0
    if is_num "$MEASURED_I" && awk -v i="$MEASURED_I" -v b="${NOISE_CHECK_LUFS:--40}" 'BEGIN{exit !(i < b)}' && audio_is_noise_only "$src"; then
        return 0
    fi
    is_num "$MEASURED_I" || return 0
    if is_num "$tp"; then
        read -r GAIN_DB GAIN_CAPPED < <(awk -v t="$TARGET_LUFS" -v i="$MEASURED_I" -v tp="$tp" -v c="$TRUE_PEAK_CEILING" \
            'BEGIN { g=t-i; cap=0; if (tp+g > c) { g=c-tp; cap=1 } printf "%.2f %d\n", g, cap }')
    else
        GAIN_DB=$(awk -v t="$TARGET_LUFS" -v i="$MEASURED_I" 'BEGIN { printf "%.2f", t-i }')
    fi
}

peak_db() {
    ffmpeg -hide_banner -nostdin -nostats -i "$1" -vn -map 0:a:0 -af astats=metadata=0:reset=0 -f null - </dev/null 2>&1 \
        | awk '/Overall/ {o=1} o && /Peak level dB:/ {print $NF; exit}'
}

compute_gain_peak() {
    PEAK_SRC=$(peak_db "$1"); PEAK_SILENT=0; GAIN_DB="0.000"; CAL_BITRATE=""
    if [[ "$PEAK_SRC" == "-inf" ]]; then PEAK_SILENT=1; return 0; fi
    if is_num "$PEAK_SRC" && awk -v p="$PEAK_SRC" -v f="${SILENCE_FLOOR_DB:--60}" 'BEGIN{exit !(p < f)}'; then
        PEAK_SILENT=1; return 0
    fi
    if is_num "$PEAK_SRC" && awk -v p="$PEAK_SRC" -v b="${NOISE_CHECK_BELOW_DB:--30}" 'BEGIN{exit !(p < b)}' && audio_is_noise_only "$1"; then
        PEAK_SILENT=1; return 0
    fi
    is_num "$PEAK_SRC" || return 1
    GAIN_DB=$(awk -v t="$TARGET_PEAK_DB" -v p="$PEAK_SRC" 'BEGIN{printf "%.3f", t - p}')
}

audio_gain_filter() {
    local src="$1" gain="$2" ch="${A_CHANNELS:-}"
    [[ -n "$ch" ]] || ch=$(ffprobe -v error -select_streams a:0 -show_entries stream=channels -of csv=p=0 "$src" </dev/null 2>/dev/null | head -1 | tr -cd '0-9')
    if [[ "$ch" == "2" ]]; then
        printf 'channelmap=0|1:stereo,volume=%sdB' "$gain"
    else
        printf 'volume=%sdB' "$gain"
    fi
}

calibrate_peak() {
    local src="$1" cal="$TMP_DIR/.cal.$$.mp4" br k rc pk err derr aerr g best_g="$GAIN_DB" bbest bbest_g i tries=0
    local fb_err=999 fb_g="" fb_br="" fb_pk="" fb_e=""
    local -a brs=("$AUDIO_BITRATE") offs=(0.03 -0.03 0.06 -0.06 0.10 -0.10 0.15)
    for i in 256k 320k; do
        awk -v a="${AUDIO_BITRATE%k}" -v b="${i%k}" 'BEGIN{exit !(b>a)}' && brs+=("$i")
    done
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
                   -af "$(audio_gain_filter "$src" "$g")" -c:a aac -b:a "$br" -f mp4 "$cal" </dev/null 2>>"$LOG" &
            FF_PID=$!; wait "$FF_PID"; rc=$?; FF_PID=""
            if (( rc != 0 )); then rm -f "$cal"; CURRENT_CAL=""; return 1; fi
            pk=$(peak_db "$cal")
            if ! is_num "$pk"; then rm -f "$cal"; CURRENT_CAL=""; return 1; fi
            err=$(awk -v t="$TARGET_PEAK_DB" -v p="$pk" 'BEGIN{printf "%.3f", t - p}')
            derr=$(awk -v e="$err" -v h="$half" 'BEGIN{printf "%.3f", e - h}')
            aerr=$(awk -v e="$derr" 'BEGIN{printf "%.3f", (e<0)?-e:e}')
            log "  CALIBRATE #${tries} (${br}): gain ${g} dB -> peak ${pk} dB (target ${TARGET_PEAK_DB} dB, err ${err} dB)"
            if awk -v e="$err" -v tol="$PEAK_TOLERANCE" 'BEGIN{exit !(e>=-0.001 && e<=tol)}'; then
                GAIN_DB="$g"; CAL_BITRATE="$br"; CAL_PEAK="$pk"; rm -f "$cal"; CURRENT_CAL=""; return 0
            fi
            if awk -v e="$err" -v f="$PEAK_FALLBACK_TOLERANCE" -v b="$fb_err" 'BEGIN{exit !(f>0 && e>=-0.001 && e<=f && e<b)}'; then
                fb_err="$err"; fb_g="$g"; fb_br="$br"; fb_pk="$pk"; fb_e="$err"
            fi
            if awk -v e="$aerr" -v b="$bbest" 'BEGIN{exit !(e<b)}'; then bbest="$aerr"; bbest_g="$g"; fi
            if (( k <= 5 )); then
                g=$(awk -v g="$g" -v e="$derr" 'BEGIN{step=(e<0)?e*0.9:e*0.85; printf "%.3f", g + step}')
            else
                g=$(awk -v g="$bbest_g" -v o="${offs[$(( (k - 6) % ${#offs[@]} ))]}" 'BEGIN{printf "%.3f", g - o}')
            fi
        done
        best_g="$bbest_g"
        [[ -n "$fb_g" && "$br" != "${brs[0]}" ]] && break
    done

    rm -f "$cal"; CURRENT_CAL=""
    if [[ -n "$fb_g" ]]; then
        GAIN_DB="$fb_g"; CAL_BITRATE="$fb_br"; CAL_PEAK="$fb_pk"
        PEAK_ERR_LO="-0.001"; PEAK_ERR_HI="$PEAK_FALLBACK_TOLERANCE"
        printf "  ${C_YELLOW}[Audio] APPROXIMATE:${C_RESET} peak %s dB (target %s dB, error %s dB)\n" "$fb_pk" "$TARGET_PEAK_DB" "$fb_e"
        return 0
    fi
    return 1
}

run_ffmpeg() {
    local src="$1" tmp="$2" vmode="$3" amode="$4" gain="$5" src_vcodec="$6"
    local -a va aa
    if [[ "$vmode" == "copy" ]]; then
        va=(-c:v copy)
        # Ensure HEVC MP4 uses hvc1 tag so Android Gallery & WhatsApp open it natively
        [[ "$src_vcodec" == "hevc" ]] && va+=(-tag:v hvc1)
    else
        va=(
            -c:v libx264
            -preset fast
            -crf 18
            -profile:v high
            -level:v 4.1
            -pix_fmt yuv420p
            -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2"
            -fps_mode passthrough
        )
    fi

    case "$amode" in
        gain)  aa=(-map 0:a:0 -af "$(audio_gain_filter "$src" "$gain")" -c:a aac -b:a "${CAL_BITRATE:-$AUDIO_BITRATE}") ;;
        acopy) aa=(-map 0:a:0 -c:a copy) ;;
        *)     aa=(-an) ;;
    esac

    ffmpeg -hide_banner -nostdin -nostats -loglevel "$FFMPEG_LOGLEVEL" -y \
        -i "$src" -map 0:v:0 "${va[@]}" "${aa[@]}" \
        -movflags +faststart -f mp4 "$tmp" </dev/null 2>>"$LOG" &
    FF_PID=$!
    wait "$FF_PID"; local rc=$?
    FF_PID=""
    return "$rc"
}

verify_output() {
    local src="$1" out="$2" want_audio="$3" src_pk="$4" src_dur="$5" vmode="$6"
    local o_pk o_dur diff tol errs
    VERIFY_WHY=""
    [[ -s "$out" ]] || { VERIFY_WHY="empty output"; return 1; }
    probe_streams "$out"

    if [[ -z "$V_CODEC" || "$V_CODEC" == "none" || "$V_CODEC" == "unknown" || "$V_TAG" == bvc* ]]; then
        VERIFY_WHY="output video codec unsupported ($V_CODEC/$V_TAG)"; return 1
    fi
    if [[ "$V_PIX_FMT" != "yuv420p" && "$V_PIX_FMT" != "yuvj420p" ]]; then
        VERIFY_WHY="incompatible pixel format ($V_PIX_FMT)"; return 1
    fi
    if (( want_audio == 1 )) && [[ -z "$A_CODEC" ]]; then VERIFY_WHY="output missing audio"; return 1; fi
    if (( want_audio == 0 )) && [[ -n "$A_CODEC" ]];  then VERIFY_WHY="unexpected audio"; return 1; fi

    o_pk=$(count_vpackets "$out")
    if [[ "$o_pk" =~ ^[0-9]+$ && "$src_pk" =~ ^[0-9]+$ ]]; then
        if [[ "$vmode" == "copy" ]]; then tol=0; else tol=$(( src_pk / 100 + 2 )); fi
        diff=$(( o_pk > src_pk ? o_pk - src_pk : src_pk - o_pk ))
        (( diff <= tol )) || { VERIFY_WHY="video packets $o_pk vs source $src_pk"; return 1; }
    else
        VERIFY_WHY="cannot count video packets"; return 1
    fi

    o_dur=$(video_duration "$out")
    [[ -n "$o_dur" ]] || { VERIFY_WHY="missing duration"; return 1; }
    if [[ -n "$src_dur" ]]; then
        if ! awk -v a="$o_dur" -v b="$src_dur" 'BEGIN { d=a-b; if (d<0) d=-d; t=b*0.02; if (t<0.5) t=0.5; exit !(d<=t) }'; then
            VERIFY_WHY="duration $o_dur vs source $src_dur"; return 1
        fi
    fi

    if (( want_audio == 1 )) && [[ "$NORM_MODE" == "peak" && "${PEAK_SILENT:-0}" == "0" ]]; then
        local opk oerr
        opk=$(peak_db "$out")
        is_num "$opk" || { VERIFY_WHY="cannot measure output peak"; return 1; }
        oerr=$(awk -v t="$TARGET_PEAK_DB" -v p="$opk" 'BEGIN{printf "%.3f", t - p}')
        awk -v e="$oerr" -v lo="${PEAK_ERR_LO:--0.001}" -v hi="${PEAK_ERR_HI:-0.05}" 'BEGIN{exit !(e>=lo && e<=hi)}' || {
            VERIFY_WHY="output peak ${opk} dB outside target window (${TARGET_PEAK_DB} dB)"; return 1
        }
    fi

    if [[ "$VERIFY_DECODE" == "1" ]]; then
        if [[ -n "$(video_stream_errors "$out")" && -z "$(video_stream_errors "$src")" ]]; then
            VERIFY_WHY="output video bitstream errors"; return 1
        fi
        if (( want_audio == 1 )); then
            errs=$(audio_decode_errors "$out")
            if [[ -n "$errs" && -z "$(audio_decode_errors "$src")" ]]; then
                VERIFY_WHY="output audio decode errors"; return 1
            fi
        fi
    fi
    return 0
}

process_file() {
    local src="$1" orig_name clean_name target_path tmp_path
    local vstreams vcodec vtag vpix acodec src_pk src_dur vprimary a1 attempt vmode amode out_size
    local -a ladder=()
    LAST_OUTPUT=""
    orig_name=$(basename "$src")
    clean_name=$(sanitize_name "$orig_name")
    target_path=$(get_unique_dest "$VIDEO_OUT" "$clean_name")
    tmp_path="$TMP_DIR/${clean_name%.mp4}.$$.tmp.mp4"
    CURRENT_TMP="$tmp_path"

    printf "${C_CYAN}[*] Processing:${C_RESET} %s\n" "$orig_name"
    log "Processing video: $orig_name"

    probe_streams "$src"
    vstreams=$V_COUNT; vcodec=$V_CODEC; vtag=$V_TAG; vpix=$V_PIX_FMT; acodec=$A_CODEC

    if (( vstreams == 0 )); then
        printf "  ${C_YELLOW}[SKIP] No video stream detected.${C_RESET}\n"
        CURRENT_TMP=""; return 2
    fi

    if [[ -z "$vcodec" || "$vcodec" == "none" || "$vcodec" == "unknown" ]] || { [[ "$vtag" == bvc* ]] && [[ "$vcodec" != "bvc2" ]]; }; then
        CURRENT_TMP=""
        if [[ -n "${NORMALIZE_PASS2:-}" || "$KEEP_ORIGINAL" == "1" ]]; then return 3; fi
        printf "  ${C_YELLOW}[bvc2] Unsupported ByteVC2 stream; trying H.264 re-download.${C_RESET}\n"
        if redownload_h264 "${orig_name%.*}" "$src"; then
            printf "  ${C_GREEN}[✓] Re-downloaded H.264 copy; normalizing.${C_RESET}\n"
            NORMALIZE_PASS2=1 process_file "$REDL_OUT"
            local rc=$?
            (( rc == 0 )) && return 4
            return "$rc"
        fi
        printf "  ${C_YELLOW}[!] Could not get H.264 copy (%s). Original kept.${C_RESET}\n" "${REDL_REASON:-unknown}"
        return 3
    fi

    # Only stream-copy standard 8-bit yuv420p H.264/HEVC/MPEG4; re-encode 10-bit or exotic formats to 8-bit H.264
    if [[ "$vcodec" =~ ^(h264|hevc|mpeg4)$ ]] && [[ "$vpix" == "yuv420p" || "$vpix" == "yuvj420p" ]]; then
        vprimary="copy"
    else
        vprimary="enc"
        printf "  ${C_BLUE}[Video] Transcoding (%s / %s) -> 8-bit H.264 yuv420p for compatibility.${C_RESET}\n" "$vcodec" "${vpix:-?}"
    fi

    a1="none"
    if [[ -n "$acodec" && "$NORM_MODE" == "peak" ]]; then
        if ! compute_gain_peak "$src"; then
            printf "  ${C_RED}[ERROR] Audio could not be measured. Original kept.${C_RESET}\n" >&2
            CURRENT_TMP=""; return 1
        fi
        if (( PEAK_SILENT == 0 )); then
            if ! calibrate_peak "$src"; then
                printf "  ${C_RED}[ERROR] Target peak (%s dB) unreachable. Original kept.${C_RESET}\n" "$TARGET_PEAK_DB" >&2
                CURRENT_TMP=""; return 1
            fi
        fi
        printf "  ${C_BLUE}[Audio] Peak:${C_RESET} %s dB -> target %s dB (%s%%) -> Gain: %s dB\n" \
               "$PEAK_SRC" "$TARGET_PEAK_DB" "$PEAK_PERCENT" "$GAIN_DB"
        a1="gain"
    elif [[ -n "$acodec" ]]; then
        compute_gain_lufs "$src"
        printf "  ${C_BLUE}[Audio] Measured:${C_RESET} %s LUFS -> Gain: %s dB (Target: %s LUFS)\n" \
               "${MEASURED_I:-N/A}" "$GAIN_DB" "$TARGET_LUFS"
        a1="gain"
        [[ "$GAIN_DB" == "0.00" && "$acodec" == "aac" ]] && a1="acopy"
    fi

    if [[ -z "$acodec" ]]; then
        ladder=("${vprimary}:none"); [[ "$vprimary" == "copy" ]] && ladder+=("enc:none")
    elif [[ "$NORM_MODE" == "peak" ]]; then
        if [[ "$vprimary" == "copy" ]]; then ladder=("copy:gain" "enc:gain"); else ladder=("enc:gain"); fi
    elif [[ "$vprimary" == "copy" ]]; then
        ladder=("copy:$a1" "enc:$a1" "copy:acopy" "enc:acopy")
    else
        ladder=("enc:$a1" "enc:acopy")
    fi

    src_pk=$(count_vpackets "$src")
    src_dur=$(video_duration "$src")

    for attempt in "${ladder[@]}"; do
        vmode="${attempt%%:*}"; amode="${attempt##*:}"
        rm -f "$tmp_path"
        [[ "$attempt" != "${ladder[0]}" ]] && printf "  ${C_YELLOW}[!] Fallback: video=%s audio=%s${C_RESET}\n" "$vmode" "$amode"
        log "  ATTEMPT video=$vmode audio=$amode"
        if ! run_ffmpeg "$src" "$tmp_path" "$vmode" "$amode" "${GAIN_DB:-0.00}" "$vcodec"; then
            log "  ATTEMPT failed (ffmpeg error): video=$vmode audio=$amode"
            continue
        fi
        local want_audio=1; [[ "$amode" == "none" ]] && want_audio=0
        if verify_output "$src" "$tmp_path" "$want_audio" "$src_pk" "$src_dur" "$vmode"; then
            out_size=$(wc -c < "$tmp_path" 2>/dev/null || echo 0)
            touch -r "$src" "$tmp_path" 2>/dev/null || true
            if mv -f "$tmp_path" "$target_path"; then
                if [[ "$KEEP_ORIGINAL" != "1" ]]; then
                    rm -f "$src"
                    queue_scan "$src"
                fi
                queue_scan "$target_path"
                LAST_OUTPUT="$target_path"
                printf "  ${C_GREEN}[✓] Verified & Saved:${C_RESET} %s (%s bytes)\n" "$(basename "$target_path")" "$out_size"
                log "  SUCCESS: $orig_name -> $(basename "$target_path") (video=$vmode audio=$amode)"
                CURRENT_TMP=""; return 0
            fi
            break
        fi
        log "  ATTEMPT rejected: $VERIFY_WHY"
    done

    rm -f "$tmp_path"
    printf "  ${C_RED}[ERROR] All attempts failed. Source preserved.${C_RESET}\n" >&2
    CURRENT_TMP=""; return 1
}

on_interrupt() {
    [[ -n "$FF_PID" ]] && kill "$FF_PID" 2>/dev/null && wait "$FF_PID" 2>/dev/null
    [[ -n "$CURRENT_TMP" && -f "$CURRENT_TMP" ]] && rm -f "$CURRENT_TMP"
    [[ -n "$CURRENT_CAL" && -f "$CURRENT_CAL" ]] && rm -f "$CURRENT_CAL"
    (( ${SCAN_OWNER:-0} == 1 )) && [[ -n "${SCAN_QUEUE:-}" ]] && rm -f "$SCAN_QUEUE"
    exit 130
}
trap on_interrupt INT TERM HUP

mkdir -p "$VIDEO_OUT" "$TMP_DIR" "$(dirname "$LOG")"
: > "$TMP_DIR/.nomedia" 2>/dev/null || true
find "$TMP_DIR" -maxdepth 1 -type f \( -name '*.tmp.mp4' -o -name '.cal.*' \) -mmin +60 -delete 2>/dev/null || true

if [[ -n "$SINGLE_FILE" ]]; then
    [[ -f "$SINGLE_FILE" ]] || { echo "[ERROR] File not found: $SINGLE_FILE" >&2; exit 1; }
    process_file "$SINGLE_FILE"; rc=$?
    [[ -n "$LAST_OUTPUT" ]] && printf 'OUTPUT=%s\n' "$LAST_OUTPUT"
    [[ -n "${NORMALIZE_RESULT_FILE:-}" ]] && printf 'OUTPUT=%s\n' "$LAST_OUTPUT" > "$NORMALIZE_RESULT_FILE"
    (( rc == 4 )) && rc=0
    if (( SCAN_OWNER == 1 )); then scan_queue "$SCAN_QUEUE"; rm -f "$SCAN_QUEUE"; fi
    exit "$rc"
fi

count_ok=0; count_fail=0; count_skip=0; count_bvc2=0; count_unsup=0
for dir in "${INPUT_DIRS[@]}"; do
    [[ -d "$dir" ]] || continue
    while IFS= read -r -d '' src <&3; do
        [[ -f "$src" ]] || continue
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
             \) ! -regex '.*\.f[0-9]+\.[A-Za-z0-9]+$' -print0 2>/dev/null)
done

printf "${C_GREEN}[✓] Summary: OK=%d, Failed=%d, Skipped=%d, bvc2_redl=%d, kept=%d${C_RESET}\n" \
       "$count_ok" "$count_fail" "$count_skip" "$count_bvc2" "$count_unsup"

if (( SCAN_OWNER == 1 )); then
    scan_queue "$SCAN_QUEUE"
    rm -f "$SCAN_QUEUE"
fi