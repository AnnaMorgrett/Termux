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
readonly LOG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/media_processor_log.txt"

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
            queue_scan "$dest"
            log "MOVED: $filename -> $(basename "$dest")"
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

if (( SCAN_OWNER == 1 )); then
    scan_queue "$SCAN_QUEUE"
    rm -f "$SCAN_QUEUE"
fi
