#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  @file        share_handler.sh
#  @brief       Android "Share to Termux" -> queue. Called by the two small scripts
#               that shortcuts.sh puts in ~/bin:
#                 termux-url-opener  <link>      (shared link)
#                 termux-file-editor <file>...   (shared video, or shared text saved as .txt)
#  @version     1.0.0
#  Usage: share_handler.sh url "<text containing a link>"
#         share_handler.sh files <path>...
# ═══════════════════════════════════════════════════════════════════════════════
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOME_DL="${HOME:-/data/data/com.termux/files/home}/downloads"     # where Termux saves shared files
Q="$SCRIPT_DIR/q.sh"

say() {   # print + short on-screen toast (toast only if Termux:API is installed; never blocks)
    echo "$*"
    if command -v termux-toast &>/dev/null; then
        if command -v timeout &>/dev/null; then timeout 3 termux-toast -s "$*" >/dev/null 2>&1 || true
        else termux-toast -s "$*" >/dev/null 2>&1 & fi
    fi
}
last_line() { printf '%s\n' "$1" | tail -n 1; }
is_video() { case "${1,,}" in *.mp4|*.mkv|*.webm|*.mov|*.avi|*.3gp|*.ts|*.flv|*.m4v) return 0 ;; *) return 1 ;; esac; }

queued=0; problems=0
# did "q add" really queue something? (it exits 0 for duplicates too, with a "duplicate: ..." line)
queued_ok() { [[ "$1" == *"queued job"* || "$1" == *"requeued"* ]]; }
add_link() {   # add_link URL
    local out; out=$(Q_NO_BG=1 bash "$Q" add "$1" 2>&1)
    if queued_ok "$out"; then (( ++queued )); say "Queued: $(last_line "$out")"
    else (( ++problems )); say "$(last_line "$out")"; fi
}

mode="${1:-}"; [[ $# -gt 0 ]] && shift
case "$mode" in
    url)
        text="${1:-}"
        if ! printf '%s' "$text" | grep -qE 'https?://[^[:space:]]+'; then say "No link found in the shared text"; exit 1; fi
        add_link "$(printf '%s' "$text" | grep -oE 'https?://[^[:space:]]+' | head -1)"
        ;;
    files)
        [[ $# -ge 1 ]] || { say "No file received"; exit 1; }
        for f in "$@"; do
            if [[ ! -f "$f" ]]; then (( ++problems )); say "File not found: $(basename "$f")"; continue; fi
            name="$(basename "$f")"
            if is_video "$name"; then
                # A copy that Termux made in ~/downloads is ours to delete after a verified result.
                # Any other path is the user's real file: never deleted.
                if [[ "$(cd "$(dirname "$f")" && pwd)" == "$HOME_DL" ]]; then
                    out=$(Q_NO_BG=1 bash "$Q" add --consume "$f" 2>&1); rc=$?
                else
                    out=$(Q_NO_BG=1 bash "$Q" add "$f" 2>&1); rc=$?
                fi
                if [[ $rc == 0 ]] && queued_ok "$out"; then (( ++queued )); say "Queued: $name"; else (( ++problems )); say "$name: $(last_line "$out")"; fi
            elif [[ "${name,,}" == *.txt ]] && (( $(stat -c %s "$f" 2>/dev/null || echo 0) <= 65536 )); then
                # shared text that was more than a bare link ("Check out this video https://...")
                links=$(grep -oE 'https?://[^[:space:]]+' "$f" | head -5)
                if [[ -z "$links" ]]; then (( ++problems )); say "No link found in $name"; continue; fi
                while IFS= read -r u; do add_link "$u"; done <<< "$links"
                [[ "$(cd "$(dirname "$f")" && pwd)" == "$HOME_DL" ]] && rm -f "$f"
            else
                (( ++problems )); say "Not a video or a link: $name"
            fi
        done
        ;;
    *) echo "Usage: share_handler.sh url \"<text>\" | files <path>..." >&2; exit 2 ;;
esac

(( queued > 0 )) && bash "$Q" bg >/dev/null 2>&1      # one background worker for everything just queued
exit $(( queued == 0 && problems > 0 ? 1 : 0 ))
