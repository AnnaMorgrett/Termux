#!/usr/bin/env bash
# scan_lib.sh - shared Android media-scan helper (source it; do not run).
# scan_queue FILE: scans every existing path listed in FILE in ONE batch, oldest first.
# Needs C_GREEN/C_YELLOW/C_RESET (optional; empty is fine).
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
