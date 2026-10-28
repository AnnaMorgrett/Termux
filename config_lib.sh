#!/usr/bin/env bash
# config_lib.sh - safe user-config loader (source it; do not run).
# load_config FILE: reads KEY=VALUE lines for a fixed list of keys. The file is NEVER
# executed; values may only contain letters, digits and . _ - ; real environment
# variables always win over the file. Missing file = defaults.
CONFIG_KEYS="NORM_MODE PEAK_PERCENT PEAK_TOLERANCE PEAK_FALLBACK_TOLERANCE TARGET_LUFS TRUE_PEAK_CEILING VERIFY_DECODE AUDIO_BITRATE FFMPEG_LOGLEVEL"
load_config() {
    local f="$1" line k v
    [[ -f "$f" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^([A-Z_]+)=([A-Za-z0-9._-]*)$ ]] || continue
        k="${BASH_REMATCH[1]}"; v="${BASH_REMATCH[2]}"
        case " $CONFIG_KEYS " in *" $k "*) ;; *) continue ;; esac
        [[ -z "${!k+x}" ]] && export "$k=$v"
    done < "$f"
    return 0
}
