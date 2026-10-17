#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  download.sh — Dedicated yt-dlp media downloader
#  Supports: Android (Termux) & PC (Linux / macOS / Windows Git Bash)
# ═══════════════════════════════════════════════════════════════════════
set -eu

# Auto-detect Environment
if [ -d "/data/data/com.termux" ] || [ -n "${TERMUX_VERSION:-}" ]; then
    SD="${MEDIA_DIR:-/storage/emulated/0}"
else
    SD="${MEDIA_DIR:-$HOME/TermuxMedia}"
fi

readonly DL_DIR="$SD/Download/yt-dlp"

if [[ $# -lt 1 ]]; then
    echo "Usage: dl <url> [extra yt-dlp options...]" >&2
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
