#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  @file        download.sh
#  @brief       Dedicated media ingestion wrapper powered by yt-dlp.
#  @author      Anna Morgrett (https://github.com/AnnaMorgrett/Termux)
#  @license     MIT
#  @version     2.2.0
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

# ── Color Output (ANSI) ───────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    C_BLUE='\033[0;34m'
    C_GREEN='\033[0;32m'
    C_RED='\033[0;31m'
    C_RESET='\033[0m'
else
    C_BLUE='' C_GREEN='' C_RED='' C_RESET=''
fi

# ── Environment & Path Discovery ──────────────────────────────────────────────
if [[ -d "/data/data/com.termux" || -n "${TERMUX_VERSION:-}" ]]; then
    SD="${MEDIA_DIR:-/storage/emulated/0}"
else
    SD="${MEDIA_DIR:-$HOME/TermuxMedia}"
fi

readonly DL_DIR="$SD/Download/yt-dlp"

# ── Usage & Help ──────────────────────────────────────────────────────────────
show_help() {
    cat << EOF
Usage: dl <URL> [OPTIONS...]

Downloads media via yt-dlp directly into the ingestion folder:
  Target: $DL_DIR

Arguments:
  <URL>             The video or audio URL (TikTok, YouTube, Facebook, etc.)
  [OPTIONS...]      Any additional flags forwarded directly to yt-dlp

Environment Overrides:
  MEDIA_DIR         Custom root media folder (Default: $SD)

Examples:
  dl "https://www.tiktok.com/@user/video/123456789"
  dl "https://youtu.be/dQw4w9WgXcQ" -f bestvideo+bestaudio
EOF
}

if [[ $# -ge 1 && ("$1" == "-h" || "$1" == "--help") ]]; then
    show_help
    exit 0
fi

if [[ $# -lt 1 ]]; then
    printf "${C_RED}[ERROR] Missing URL argument.${C_RESET}\n" >&2
    show_help >&2
    exit 2
fi

# ── Download Routine ──────────────────────────────────────────────────────────
mkdir -p "$DL_DIR"

url="$1"
shift

printf "${C_BLUE}[*] Ingesting media via yt-dlp:${C_RESET} %s\n" "$url"
printf "${C_BLUE}[*] Destination folder:${C_RESET} %s\n" "$DL_DIR"

# DL_RESULT_FILE (set by worker.sh): yt-dlp appends the final path of every file here.
result_args=()
[[ -n "${DL_RESULT_FILE:-}" ]] && result_args=(--print-to-file "after_move:filepath" "$DL_RESULT_FILE")

# Run as a tracked child so a TERM to this script stops yt-dlp at once.
YT_PID=""
trap '[[ -n "$YT_PID" ]] && kill "$YT_PID" 2>/dev/null; exit 143' INT TERM HUP
yt-dlp \
    --no-mtime \
    -S "vcodec:h264,res,acodec:m4a" \
    -P "$DL_DIR" \
    -o "%(title).100B [%(id)s].%(ext)s" \
    "${result_args[@]}" \
    "$@" \
    "$url" &
YT_PID=$!
wait "$YT_PID"
YT_PID=""

printf "${C_GREEN}[✓] Download finished successfully.${C_RESET}\n"
