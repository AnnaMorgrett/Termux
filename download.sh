#!/usr/bin/env bash
# download.sh - Termux yt-dlp downloader (TikTok, Facebook, YouTube, etc.) without root.
set -euo pipefail

if [[ -t 1 ]]; then
    C_BLUE='\033[0;34m' C_GREEN='\033[0;32m' C_YELLOW='\033[0;33m' C_RED='\033[0;31m' C_RESET='\033[0m'
else
    C_BLUE='' C_GREEN='' C_YELLOW='' C_RED='' C_RESET=''
fi

readonly SD="${MEDIA_DIR:-/storage/emulated/0}"
readonly DL_DIR="$SD/Download/yt-dlp"
readonly FB_COOKIES="${FB_COOKIES:-$HOME/fb_cookies.txt}"

show_help() {
    cat << EOF
Usage: dl <URL> [yt-dlp options...]

Downloads media via yt-dlp into:
  $DL_DIR
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { show_help; exit 0; }
if [[ $# -lt 1 ]]; then
    printf "${C_RED}[ERROR] Missing URL argument.${C_RESET}\n" >&2
    show_help >&2
    exit 2
fi

mkdir -p "$DL_DIR"
url="$1"
shift

site_args=()
case "${url,,}" in
    *facebook.com*|*fb.watch*|*fb.com*)
        [[ -s "$FB_COOKIES" ]] && site_args+=(--cookies "$FB_COOKIES")
        if python3 -c 'import curl_cffi' 2>/dev/null; then
            site_args+=(--impersonate firefox)
        else
            printf "${C_YELLOW}[~] Tip: install curl_cffi for better Facebook support (pip install curl_cffi).${C_RESET}\n"
        fi
        ;;
    *tiktok.com*)
        site_args+=(--extractor-args "tiktok:api_hostname=api22-normal-c-useast2a.tiktokv.com")
        ;;
esac

result_args=()
[[ -n "${DL_RESULT_FILE:-}" ]] && result_args=(--print-to-file "after_move:filepath" "$DL_RESULT_FILE")

printf "${C_BLUE}[*] Downloading:${C_RESET} %s\n" "$url"

YT_PID=""
trap '[[ -n "$YT_PID" ]] && kill "$YT_PID" 2>/dev/null; exit 143' INT TERM HUP

yt-dlp \
    --no-mtime \
    -S "vcodec:h264,res,acodec:m4a" \
    --merge-output-format mp4 \
    -P "$DL_DIR" \
    -o "%(title).100B [%(id)s].%(ext)s" \
    "${result_args[@]}" \
    "${site_args[@]}" \
    "$@" \
    "$url" &
YT_PID=$!
wait "$YT_PID"
YT_PID=""

printf "${C_GREEN}[✓] Download complete.${C_RESET}\n"