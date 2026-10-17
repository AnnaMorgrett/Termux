#!/data/data/com.termux/files/usr/bin/bash
# ═══════════════════════════════════════════════════════════════════════
#  download.sh — Dedicated yt-dlp media downloader
#  Target Location: /storage/emulated/0/Termux/download.sh
# ═══════════════════════════════════════════════════════════════════════
set -eu

readonly DL_DIR="/storage/emulated/0/Download/yt-dlp"

if [[ $# -lt 1 ]]; then
    echo "Usage: download.sh <url> [extra yt-dlp options...]" >&2
    exit 1
fi

mkdir -p "$DL_DIR"

url="$1"
shift

echo "[*] Downloading: $url"
yt-dlp --no-mtime \
       -P "$DL_DIR" \
       -o "%(title)s.%(ext)s" \
       "$@" "$url"
