#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  @file        move_assets.sh
#  @brief       Non-video asset scanner, safe relocator, & MediaScanner synchronizer.
#  @author      Anna Morgrett (https://github.com/AnnaMorgrett/Termux)
#  @license     MIT
#  @version     2.1.0
# ═══════════════════════════════════════════════════════════════════════════════
set -u

# ── Color Output (ANSI) ───────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    C_BLUE='\033[0;34m'
    C_GREEN='\033[0;32m'
    C_YELLOW='\033[0;33m'
    C_RED='\033[0;31m'
    C_RESET='\033[0m'
else
    C_BLUE='' C_GREEN='' C_YELLOW='' C_RED='' C_RESET=''
fi

# ── Environment & Path Discovery ──────────────────────────────────────────────
if [[ -d "/data/data/com.termux" || -n "${TERMUX_VERSION:-}" ]]; then
    SD="${MEDIA_DIR:-/storage/emulated/0}"
else
    SD="${MEDIA_DIR:-$HOME/TermuxMedia}"
fi

readonly INPUT_DIRS=(
    "$SD/DCIM/TikTok"
    "$SD/Download/yt-dlp"
)
readonly ASSET_OUT="$SD/Pictures/TikTok_Assets"
readonly LOG="$SD/Documents/.media_processor.log"

# ── Usage & Help ──────────────────────────────────────────────────────────────
show_help() {
    cat << EOF
Usage: move_assets.sh [OPTIONS]

Scans TikTok and yt-dlp folders for non-video assets (photos, stickers, GIFs),
relocates them safely to Pictures/TikTok_Assets without overwriting, and triggers
Android's native MediaScanner.

Scanned Directories:
  - $SD/DCIM/TikTok
  - $SD/Download/yt-dlp

Target Directory:
  - $ASSET_OUT

Supported Formats:
  Images:      JPG, JPEG, PNG, BMP, TIFF, TIF, HEIC, HEIF, SVG
  Animations:  GIF, WEBP

Options:
  -h, --help   Display this documentation.
EOF
}

if [[ $# -ge 1 && ("$1" == "-h" || "$1" == "--help") ]]; then
    show_help
    exit 0
fi

# ── Utilities ─────────────────────────────────────────────────────────────────
log() {
    printf '[%s] [ASSETS] %s\n' "$(date '+%F %T')" "$*" >> "$LOG"
}

media_scan() {
    local target="$1"
    if command -v termux-media-scan &>/dev/null; then
        termux-media-scan "$target" 2>/dev/null || true
    elif command -v am &>/dev/null; then
        am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE \
               -d "file://$target" >/dev/null 2>&1 || true
    fi
}

get_unique_dest() {
    local dir="$1" fname="$2"
    local base="${fname%.*}" ext="${fname##*.}" out="$dir/$fname" i=1
    while [[ -e "$out" ]]; do
        out="$dir/${base}_$((i++)).$ext"
    done
    printf '%s' "$out"
}

# ── Execution ─────────────────────────────────────────────────────────────────
mkdir -p "$ASSET_OUT" "$(dirname "$LOG")"
log "Beginning non-video asset scan..."
printf "${C_BLUE}[*] Scanning for non-video assets...${C_RESET}\n"

moved_count=0

for dir in "${INPUT_DIRS[@]}"; do
    [[ -d "$dir" ]] || continue
    while IFS= read -r -d '' src; do
        filename=$(basename "$src")
        dest=$(get_unique_dest "$ASSET_OUT" "$filename")

        if mv -n "$src" "$dest" 2>/dev/null; then
            media_scan "$dest"
            log "MOVED & SCANNED: $filename -> $(basename "$dest")"
            printf "  ${C_GREEN}[✓] Relocated:${C_RESET} %s -> %s\n" "$filename" "$(basename "$dest")"
            (( ++moved_count )) || true
        else
            log "ERROR: Failed moving $filename"
            printf "  ${C_RED}[!] Error moving:${C_RESET} %s\n" "$filename" >&2
        fi
    done < <(find "$dir" -maxdepth 1 -type f \( \
                 -iname '*.jpg'  -o -iname '*.jpeg' -o -iname '*.png'  \
              -o -iname '*.gif'  -o -iname '*.webp' -o -iname '*.bmp'  \
              -o -iname '*.tiff' -o -iname '*.tif'  -o -iname '*.heic' \
              -o -iname '*.heif' -o -iname '*.svg'                     \
             \) -print0 2>/dev/null)
done

log "Asset stage completed. Relocated count: $moved_count"
printf "${C_GREEN}[✓] Assets relocated:${C_RESET} %d\n" "$moved_count"
