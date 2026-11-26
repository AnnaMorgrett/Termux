#!/usr/bin/env bash
# config.sh - Safe user-configuration loader and validator for Termux Media Pipeline.

readonly CONFIG_KEYS=(
    NORM_MODE
    PEAK_PERCENT
    PEAK_TOLERANCE
    PEAK_FALLBACK_TOLERANCE
    TARGET_LUFS
    TRUE_PEAK_CEILING
    VERIFY_DECODE
    AUDIO_BITRATE
    WORKER_JOBS
    FFMPEG_LOGLEVEL
)

config_default() {
    case "$1" in
        NORM_MODE)               echo "peak" ;;
        PEAK_PERCENT)            echo "100" ;;
        PEAK_TOLERANCE)          echo "0.05" ;;
        PEAK_FALLBACK_TOLERANCE) echo "0.30" ;;
        TARGET_LUFS)             echo "-9" ;;
        TRUE_PEAK_CEILING)       echo "-1.0" ;;
        VERIFY_DECODE)           echo "1" ;;
        AUDIO_BITRATE)           echo "192k" ;;
        WORKER_JOBS)             echo "2" ;;
        FFMPEG_LOGLEVEL)         echo "info" ;;
        *) return 1 ;;
    esac
}

validate_config_kv() {
    local k="$1" v="$2"
    case "$k" in
        NORM_MODE)
            [[ "$v" == "peak" || "$v" == "lufs" ]] ;;
        PEAK_PERCENT)
            [[ "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]] && awk -v p="$v" 'BEGIN{exit !(p>=0 && p<=100)}' ;;
        PEAK_TOLERANCE)
            [[ "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]] && awk -v t="$v" 'BEGIN{exit !(t>=0.01 && t<=1)}' ;;
        PEAK_FALLBACK_TOLERANCE)
            [[ "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]] && awk -v t="$v" 'BEGIN{exit !(t>=0 && t<=1)}' ;;
        TARGET_LUFS)
            [[ "$v" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] && awk -v n="$v" 'BEGIN{exit !(n>=-40 && n<=0)}' ;;
        TRUE_PEAK_CEILING)
            [[ "$v" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] && awk -v n="$v" 'BEGIN{exit !(n>=-20 && n<=0)}' ;;
        VERIFY_DECODE)
            [[ "$v" == "0" || "$v" == "1" ]] ;;
        AUDIO_BITRATE)
            [[ "$v" =~ ^[0-9]{2,3}k$ ]] && (( ${v%k} >= 64 && ${v%k} <= 320 )) ;;
        WORKER_JOBS)
            [[ "$v" =~ ^[1-4]$ ]] ;;
        FFMPEG_LOGLEVEL)
            [[ "$v" =~ ^(quiet|error|warning|info|verbose)$ ]] ;;
        *) return 1 ;;
    esac
}

load_config() {
    local file="$1" line k v
    [[ -f "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^([A-Z_]+)=([A-Za-z0-9._-]+)$ ]] || continue
        k="${BASH_REMATCH[1]}"
        v="${BASH_REMATCH[2]}"
        validate_config_kv "$k" "$v" || continue
        [[ -z "${!k+x}" ]] && export "$k=$v"
    done < "$file"
    return 0
}

set_config_value() {
    local file="$1" key="$2" val="$3" def tmp
    validate_config_kv "$key" "$val" || return 1
    def="$(config_default "$key")"
    mkdir -p "$(dirname "$file")"
    tmp="${file}.tmp.$$"
    {
        echo "# Media Pipeline configuration (auto-managed)"
        if [[ -f "$file" ]]; then
            grep -E '^[A-Z_]+=[A-Za-z0-9._-]+$' "$file" | grep -v "^${key}=" || true
        fi
        [[ "$val" != "$def" ]] && printf '%s=%s\n' "$key" "$val"
    } > "$tmp" && mv -f "$tmp" "$file"
}