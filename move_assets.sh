#!/data/data/com.termux/files/usr/bin/bash
# ═══════════════════════════════════════════════════════════════════════
#  move_assets.sh — Non-video asset scanner, relocator, & media sync
#  Target Location: /storage/emulated/0/Termux/move_assets.sh
# ═══════════════════════════════════════════════════════════════════════
set -u

readonly SD="/storage/emulated/0"
readonly INPUT_DIRS=(
    "$SD/DCIM/TikTok"
    "$SD/Download/yt-dlp"
)
readonly ASSET_OUT="$SD/Pictures/TikTok_Assets"
readonly LOG="$SD/Documents/.media_processor.log"

log() {
    printf '[%s] [ASSETS] %s\n' "$(date '+%F %T')" "$*" >> "$LOG"
}

media_scan() {
    local target="$1"
    termux-media-scan "$target" 2>/dev/null \
        || am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE \
               -d "file://$target" >/dev/null 2>&1 \
        || true
}

get_unique_dest() {
    local dir="$1" fname="$2"
    local base="${fname%.*}" ext="${fname##*.}" out="$dir/$fname" i=1
    while [[ -e "$out" ]]; do
        out="$dir/${base}_$((i++)).$ext"
    done
    printf '%s' "$out"
}

mkdir -p "$ASSET_OUT"
log "Starting asset scan and relocation..."
moved_count=0

for dir in "${INPUT_DIRS[@]}"; do
    [[ -d "$dir" ]] || continue
    while IFS= read -r -d '' src; do
        filename=$(basename "$src")
        dest=$(get_unique_dest "$ASSET_OUT" "$filename")

        if mv -n "$src" "$dest" 2>/dev/null; then
            media_scan "$dest"
            log "MOVED & SCANNED: $filename -> $(basename "$dest")"
            (( ++moved_count )) || true
        else
            log "ERROR: Failed moving $filename"
        fi
    done < <(find "$dir" -maxdepth 1 -type f \( \
                 -iname '*.jpg'  -o -iname '*.jpeg' -o -iname '*.png'  \
              -o -iname '*.gif'  -o -iname '*.webp' -o -iname '*.bmp'  \
              -o -iname '*.tiff' -o -iname '*.tif'  -o -iname '*.heic' \
              -o -iname '*.heif' -o -iname '*.svg'                     \
             \) -print0 2>/dev/null)
done

log "Asset processing completed. Total assets relocated: $moved_count"
printf 'Assets relocated: %d\n' "$moved_count"
