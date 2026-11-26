#!/usr/bin/env bash
# share_handler.sh - Android "Share -> Termux" handler (zero Termux:API, zero root).
# Invoked automatically by ~/bin/termux-url-opener and ~/bin/termux-file-editor.
set -u

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly HOME_DL="${HOME:-/data/data/com.termux/files/home}/downloads"
readonly Q="$SCRIPT_DIR/q.sh"

is_video() {
    case "${1,,}" in
        *.mp4|*.mkv|*.webm|*.mov|*.avi|*.3gp|*.ts|*.flv|*.m4v) return 0 ;;
        *) return 1 ;;
    esac
}

extract_urls() {
    printf '%s' "$1" | grep -oE 'https?://[^[:space:]"<>'\'']+' | sed -E 's/[.,;:!?)]+$//'
}

queued=0
problems=0
queued_ok() { [[ "$1" == *"queued job"* || "$1" == *"requeued"* ]]; }

add_link() {
    local out
    out=$(Q_NO_BG=1 bash "$Q" add "$1" 2>&1)
    if queued_ok "$out"; then
        (( ++queued ))
        printf '[✓] %s\n    %s\n' "$(printf '%s\n' "$out" | tail -n 1)" "$1"
    else
        (( ++problems ))
        printf '[!] %s\n' "$(printf '%s\n' "$out" | tail -n 1)"
    fi
}

mode="${1:-}"
[[ $# -gt 0 ]] && shift

case "$mode" in
    url)
        raw_text="${1:-}"
        links=$(extract_urls "$raw_text" | head -5)
        if [[ -z "$links" ]]; then
            echo "[!] No link found in shared text."
            sleep 1.5
            exit 1
        fi
        while IFS= read -r u; do
            [[ -n "$u" ]] && add_link "$u"
        done <<< "$links"
        ;;
    files)
        [[ $# -ge 1 ]] || { echo "[!] No file received."; sleep 1.5; exit 1; }
        for f in "$@"; do
            if [[ ! -f "$f" ]]; then
                (( ++problems ))
                echo "[!] File not found: $(basename "$f")"
                continue
            fi
            name="$(basename "$f")"
            if is_video "$name"; then
                if [[ "$(cd "$(dirname "$f")" && pwd)" == "$HOME_DL" ]]; then
                    out=$(Q_NO_BG=1 bash "$Q" add --consume "$f" 2>&1); rc=$?
                else
                    out=$(Q_NO_BG=1 bash "$Q" add "$f" 2>&1); rc=$?
                fi
                if [[ $rc == 0 ]] && queued_ok "$out"; then
                    (( ++queued ))
                    echo "[✓] Queued video: $name"
                else
                    (( ++problems ))
                    echo "[!] $name: $(printf '%s\n' "$out" | tail -n 1)"
                fi
            elif [[ "${name,,}" == *.txt ]] && (( $(stat -c %s "$f" 2>/dev/null || echo 0) <= 65536 )); then
                links=$(extract_urls "$(cat "$f")" | head -5)
                if [[ -z "$links" ]]; then
                    (( ++problems ))
                    echo "[!] No link found in $name"
                    continue
                fi
                while IFS= read -r u; do
                    [[ -n "$u" ]] && add_link "$u"
                done <<< "$links"
                [[ "$(cd "$(dirname "$f")" && pwd)" == "$HOME_DL" ]] && rm -f "$f"
            else
                (( ++problems ))
                echo "[!] Unsupported shared file: $name"
            fi
        done
        ;;
    *)
        echo "Usage: share_handler.sh url \"<text>\" | files <path>..." >&2
        exit 2
        ;;
esac

if (( queued > 0 )); then
    bash "$Q" bg >/dev/null 2>&1
    echo "[*] Processing in background..."
fi

# Brief pause so Termux's share popup remains readable before closing cleanly
sleep 1.2
exit $(( queued == 0 && problems > 0 ? 1 : 0 ))