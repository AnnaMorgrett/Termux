#!/usr/bin/env bash
# media_scan.sh - Native Android MediaStore scanner (no root, no Termux:API).

scan_paths() {
    local f count=0 ok=0
    for f in "$@"; do
        [[ -n "$f" ]] || continue
        (( ++count ))
        if [[ -x "/system/bin/content" ]] && /system/bin/content call \
            --uri content://media \
            --method scan_file \
            --arg "$f" </dev/null >/dev/null 2>&1; then
            (( ++ok ))
        elif [[ -x "/system/bin/am" ]] && /system/bin/am broadcast \
            -a android.intent.action.MEDIA_SCANNER_SCAN_FILE \
            -d "file://$f" </dev/null >/dev/null 2>&1; then
            (( ++ok ))
        fi
    done
    (( ok > 0 ))
}

scan_queue() {
    local qf="$1" f mtime
    local -a files=()
    [[ -s "$qf" ]] || return 0

    while IFS= read -r f; do
        [[ -n "$f" ]] && files+=("$f")
    done < <(
        sort -u "$qf" | while IFS= read -r q; do
            [[ -n "$q" ]] || continue
            if [[ -e "$q" ]]; then
                mtime=$(stat -c '%Y' "$q" 2>/dev/null || echo 0)
            else
                mtime=0
            fi
            printf '%s\t%s\n' "$mtime" "$q"
        done | sort -t $'\t' -k1,1nr | cut -f2-
    )

    (( ${#files[@]} > 0 )) || return 0
    if scan_paths "${files[@]}"; then
        printf "${C_GREEN:-}[✓] MediaStore synced:${C_RESET:-} %d path(s)\n" "${#files[@]}"
    fi
}