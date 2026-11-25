#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  @file        move_assets.sh
#  @brief       Non-video asset scanner, safe relocator, & MediaScanner synchronizer.
#  @author      Anna Morgrett (https://github.com/AnnaMorgrett/Termux)
#  @license     MIT
#  @version     2.2.1
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

_SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
if [[ -f "$_SCRIPT_PATH" ]]; then
    _ASSET_DIR="$(cd "$(dirname "$_SCRIPT_PATH")" && pwd)"
else
    _ASSET_DIR="$PWD"
fi

readonly INPUT_DIRS=(
    "$SD/DCIM/TikTok"
    "$SD/Pictures/TikTok"
    "$SD/Download/yt-dlp"
)
readonly ASSET_OUT="$SD/Pictures/TikTok_Assets"
readonly LOG="$_ASSET_DIR/media_processor_log.txt"

# ── Usage & Help ──────────────────────────────────────────────────────────────
show_help() {
    cat << HELP
Usage: move_assets.sh [OPTIONS]

Scans TikTok and yt-dlp folders for non-video assets (photos, stickers, GIFs),
detects extensionless images via magic bytes, restores their extension, relocates
them safely to Pictures/TikTok_Assets without overwriting, and triggers
Android's native MediaScanner.

Scanned Directories:
  - $SD/DCIM/TikTok
  - $SD/Download/yt-dlp

Target Directory:
  - $ASSET_OUT

Supported Formats:
  Images:      JPG, JPEG, PNG, BMP, TIFF, TIF, HEIC, HEIF, AVIF, JXL, SVG (incl. extensionless)
  Animations:  GIF, WEBP

Options:
  -h, --help   Display this documentation.
HELP
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
    SCAN_QUEUE="$MEDIA_SCAN_QUEUE"; SCAN_OWNER=0
else
    SCAN_QUEUE="$(mktemp)"; SCAN_OWNER=1
fi
queue_scan() { printf '%s\n' "$1" >> "$SCAN_QUEUE"; }
# shellcheck source=scan_lib.sh
if [[ -f "$_ASSET_DIR/scan_lib.sh" ]]; then
    source "$_ASSET_DIR/scan_lib.sh"
else
    scan_queue() { :; }
fi

# Detects image format from magic bytes for extensionless / unknown-extension files
detect_image_ext() {
    local file="$1" hex
    hex=$(od -An -tx1 -N 32 "$file" 2>/dev/null | tr -d ' \t\r\n')
    [[ -z "$hex" ]] && return 1

    case "$hex" in
        ffd8ff*)
            printf 'jpg'; return 0 ;;
        89504e470d0a1a0a*)
            printf 'png'; return 0 ;;
        474946383761*|474946383961*)
            printf 'gif'; return 0 ;;
        52494646????????57454250*)
            printf 'webp'; return 0 ;;
        ff0a*|0000000c4a584c200d0a870a*)
            printf 'jxl'; return 0 ;;
        424d????????00000000*)
            printf 'bmp'; return 0 ;;
        49492a00*|4d4d002a*)
            printf 'tiff'; return 0 ;;
        ????????6674797068656963*|????????6674797068656978*|????????6674797068657663*|????????6674797068657678*)
            printf 'heic'; return 0 ;;
        ????????6674797068656966*|????????667479706865696d*|????????6674797068656973*|????????667479706865766d*|????????6674797068657673*|????????667479706d696631*|????????667479706d736631*|????????667479706d696166*)
            printf 'heif'; return 0 ;;
        ????????6674797061766966*|????????6674797061766973*)
            printf 'avif'; return 0 ;;
    esac

    if head -c 512 "$file" 2>/dev/null | tr -d '\0' | grep -qiE '^[[:space:]]*(<\?xml[^>]*>[[:space:]]*)?<svg\b'; then
        printf 'svg'
        return 0
    fi

    if command -v file >/dev/null 2>&1; then
        case "$(file -b --mime-type "$file" 2>/dev/null)" in
            image/jpeg) printf 'jpg'; return 0 ;;
            image/png) printf 'png'; return 0 ;;
            image/gif) printf 'gif'; return 0 ;;
            image/webp) printf 'webp'; return 0 ;;
            image/jxl) printf 'jxl'; return 0 ;;
            image/heic) printf 'heic'; return 0 ;;
            image/heif) printf 'heif'; return 0 ;;
            image/avif) printf 'avif'; return 0 ;;
            image/bmp|image/x-ms-bmp) printf 'bmp'; return 0 ;;
            image/tiff) printf 'tiff'; return 0 ;;
            image/svg+xml) printf 'svg'; return 0 ;;
        esac
    fi

    return 1
}

get_unique_dest() {
    local dir="$1" fname="$2"
    local out="$dir/$fname" i=1
    if [[ "$fname" == *.* ]]; then
        local base="${fname%.*}" ext="${fname##*.}"
        while [[ -e "$out" ]]; do
            out="$dir/${base}_$((i++)).$ext"
        done
    else
        while [[ -e "$out" ]]; do
            out="$dir/${fname}_$((i++))"
        done
    fi
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
        [[ -f "$src" ]] || continue
        filename=$(basename "$src")
        ext_lower=""
        [[ "$filename" == *.* ]] && ext_lower="${filename##*.}" && ext_lower="${ext_lower,,}"

        case "$ext_lower" in
            jpg|jpeg|png|gif|webp|bmp|tiff|tif|heic|heif|avif|jxl|svg)
                age=$(( $(date +%s) - $(stat -c %Y "$src" 2>/dev/null || echo 0) ))
                (( age >= 0 && age < 5 )) && sleep $(( 5 - age ))
                dest_name="$filename"
                ;;
            mp4|mkv|webm|mov|avi|flv|wmv|m4v|3gp|ts|m4a|mp3|opus|ogg|wav|flac|aac|part|ytdl|tmp|temp|crdownload|json|txt|srt|vtt|ass|lrc|description|info)
                continue
                ;;
            *)
                age=$(( $(date +%s) - $(stat -c %Y "$src" 2>/dev/null || echo 0) ))
                (( age >= 0 && age < 5 )) && sleep $(( 5 - age ))
                detected_ext=$(detect_image_ext "$src") || continue
                dest_name="${filename}.${detected_ext}"
                ;;
        esac

        dest=$(get_unique_dest "$ASSET_OUT" "$dest_name")

        if mv -n "$src" "$dest" 2>/dev/null; then
            queue_scan "$src"
            queue_scan "$dest"
            log "MOVED: $filename -> $(basename "$dest")"
            printf "  ${C_GREEN}[✓] Relocated:${C_RESET} %s -> %s\n" "$filename" "$(basename "$dest")"
            (( ++moved_count )) || true
        else
            log "ERROR: Failed moving $filename"
            printf "  ${C_RED}[!] Error moving:${C_RESET} %s\n" "$filename" >&2
        fi
    done < <(find "$dir" -maxdepth 1 -type f ! -name '.*' -print0 2>/dev/null)
done

log "Asset stage completed. Relocated count: $moved_count"
printf "${C_GREEN}[✓] Assets relocated:${C_RESET} %d\n" "$moved_count"

if (( SCAN_OWNER == 1 )); then
    scan_queue "$SCAN_QUEUE"
    rm -f "$SCAN_QUEUE"
fi
