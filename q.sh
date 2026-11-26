#!/usr/bin/env bash
# q.sh - CLI front-end for the Termux media queue (`q`).
set -u

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export QUEUE_DIR="${QUEUE_DIR:-$SCRIPT_DIR/data/queue}"
readonly CONFIG_FILE="${PIPELINE_CONFIG:-$SCRIPT_DIR/data/config.conf}"
readonly LOG="$SCRIPT_DIR/media_processor_log.txt"
readonly SD="${MEDIA_DIR:-/storage/emulated/0}"

# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"
load_config "$CONFIG_FILE"

qctl() { python3 "$SCRIPT_DIR/qctl.py" "$@"; }

usage() {
    cat << 'EOF'
Usage: q <command> [args]

  add [--consume] <url|file>...   Queue URLs or local videos and process in background
  dl <url> [yt-dlp opts]          Queue one URL and wait for completion
  scan                            Queue pending videos in DCIM/TikTok and Download/yt-dlp
  run                             Run queue worker in foreground
  bg                              Start queue worker in background
  stop                            Stop worker after the current job finishes
  list [status]                   List jobs (pending | running | done | failed)
  stats                           Show job counts and worker status
  retry [ID|all]                  Retry failed jobs
  remove ID                       Delete a non-running job
  clear [done|failed|all]         Clear finished/failed jobs
  logs [N]                        Show last N log lines (default 30)
  percent [0-100]                 Get/set sample-peak target (0%=-9dBFS .. 100%=-1dBFS)
  config [KEY VALUE]              Show or update settings in data/config.conf
  selftest                        Verify atomic queue operations on storage
EOF
}

worker_running() {
    local p
    p=$(cat "$QUEUE_DIR/.worker.lock/pid" 2>/dev/null)
    [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null
}

start_bg() {
    worker_running && return 0
    mkdir -p "$QUEUE_DIR"
    if [[ -f "$QUEUE_DIR/worker.out" ]] && (( $(stat -c %s "$QUEUE_DIR/worker.out" 2>/dev/null || echo 0) > 262144 )); then
        : > "$QUEUE_DIR/worker.out"
    fi
    nohup bash "$SCRIPT_DIR/worker.sh" >> "$QUEUE_DIR/worker.out" 2>&1 < /dev/null &
    disown 2>/dev/null || true
    echo "worker started in background"
}

extract_url() {
    printf '%s' "$1" | grep -oE 'https?://[^[:space:]"<>'\'']+' | head -1 | sed -E 's/[.,;:!?)]+$//'
}

FILE_EXTRA=()
add_one() {
    local it="$1" u f
    ADD_RC=0
    if [[ "$it" =~ ^https?://[^[:space:]]+$ ]]; then
        u=$(extract_url "$it")
        qctl add --url "$u" "${@:2}"; ADD_RC=$?; return
    fi
    if [[ -e "$it" || "$it" == /* ]]; then
        f="$it"
        [[ "$f" == /* ]] || f="$(cd "$(dirname "$f")" 2>/dev/null && pwd)/$(basename "$f")"
        qctl add --file "$f" "${FILE_EXTRA[@]}"; ADD_RC=$?; return
    fi
    u=$(extract_url "$it")
    if [[ -n "$u" ]]; then
        qctl add --url "$u" "${@:2}"; ADD_RC=$?; return
    fi
    echo "not a link or file: $it" >&2
    ADD_RC=2
}

scan_folders() {
    local dir f age queued=0 dup=0 out
    for dir in "$SD/DCIM/TikTok" "$SD/Download/yt-dlp"; do
        [[ -d "$dir" ]] || continue
        while IFS= read -r -d '' f <&3; do
            age=$(( $(date +%s) - $(stat -c %Y "$f" 2>/dev/null || echo 0) ))
            (( age >= 0 && age < 5 )) && sleep $(( 5 - age ))
            out=$(qctl add --file "$f" --consume 2>&1)
            case $? in
                0) (( ++queued )) ;;
                3) (( ++dup )) ;;
                *) echo "[!] Queue error: $out" >&2; return 1 ;;
            esac
        done 3< <(find "$dir" -maxdepth 1 -type f \( -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.webm' \
                   -o -iname '*.mov' -o -iname '*.avi' -o -iname '*.3gp' -o -iname '*.ts' -o -iname '*.flv' -o -iname '*.m4v' \) \
                   ! -regex '.*\.f[0-9]+\.[A-Za-z0-9]+$' -print0 2>/dev/null)
    done
    echo "folder scan: queued=$queued already_queued=$dup"
}

cmd="${1:-help}"
[[ $# -gt 0 ]] && shift

case "$cmd" in
    add)
        [[ "${1:-}" == "--consume" ]] && { FILE_EXTRA=(--consume); shift; }
        [[ $# -ge 1 ]] || { usage >&2; exit 2; }
        bad=0
        for it in "$@"; do
            add_one "$it"
            [[ $ADD_RC == 2 ]] && bad=1
        done
        [[ "${Q_NO_BG:-}" == "1" ]] || start_bg
        exit $bad
        ;;
    dl)
        [[ $# -ge 1 ]] || { echo "Usage: dl <URL> [yt-dlp options...]" >&2; exit 1; }
        url="$1"; shift
        extra=(); for o in "$@"; do extra+=("--arg=$o"); done
        u=$(extract_url "$url")
        [[ -n "$u" ]] || { echo "not a valid URL: $url" >&2; exit 2; }
        out=$(qctl add --url "$u" "${extra[@]}" 2>&1); rc=$?
        echo "$out"
        (( rc == 2 )) && exit 2
        [[ "$out" == *"already done"* ]] && exit 0
        jid=$(printf '%s' "$out" | grep -oE '[0-9]+' | head -1)
        start_bg
        [[ -n "$jid" ]] && exec python3 "$SCRIPT_DIR/qctl.py" wait "$jid"
        ;;
    scan)   scan_folders ;;
    run)    exec bash "$SCRIPT_DIR/worker.sh" ;;
    bg)     start_bg ;;
    stop)
        if worker_running; then
            mkdir -p "$QUEUE_DIR"
            : > "$QUEUE_DIR/.stop"
            echo "stop requested (after current job finishes)"
        else
            echo "no worker running"
        fi
        ;;
    list)   qctl list ${1:+--status "$1"} ;;
    stats|status)
        echo "$(qctl stats)  worker=$(worker_running && echo running || echo idle)"
        ;;
    retry)
        if [[ "${1:-all}" == "all" ]]; then qctl retry --all; else qctl retry "$1"; fi
        [[ $? == 0 && "${Q_NO_BG:-}" != "1" ]] && start_bg
        ;;
    remove) [[ $# -ge 1 ]] || { usage >&2; exit 2; }; qctl remove "$1" ;;
    clear)
        case "${1:-done}" in
            all)         qctl clear done failed ;;
            done|failed) qctl clear "$1" ;;
            *)           usage >&2; exit 2 ;;
        esac
        ;;
    logs)   tail -n "${1:-30}" "$LOG" 2>/dev/null ;;
    percent)
        if [[ $# -eq 0 ]]; then
            cur="${PEAK_PERCENT:-$(config_default PEAK_PERCENT)}"
            db=$(awk -v p="$cur" 'BEGIN{printf "%.3f", -9 + 8.0 * (p / 100)}')
            echo "PEAK_PERCENT = ${cur}% -> target sample peak ${db} dBFS"
        else
            if set_config_value "$CONFIG_FILE" "PEAK_PERCENT" "$1"; then
                db=$(awk -v p="$1" 'BEGIN{printf "%.3f", -9 + 8.0 * (p / 100)}')
                echo "Saved: PEAK_PERCENT = ${1}% -> target sample peak ${db} dBFS"
            else
                echo "Invalid percentage (must be 0-100): $1" >&2
                exit 2
            fi
        fi
        ;;
    config)
        if [[ $# -eq 0 ]]; then
            for k in "${CONFIG_KEYS[@]}"; do
                val="${!k:-$(config_default "$k")}"
                printf '%-25s = %s\n' "$k" "$val"
            done
        elif [[ $# -eq 2 ]]; then
            if set_config_value "$CONFIG_FILE" "$1" "$2"; then
                echo "Saved: $1=$2"
            else
                echo "Invalid setting: $1=$2" >&2
                exit 2
            fi
        else
            echo "Usage: q config [KEY VALUE]" >&2
            exit 2
        fi
        ;;
    selftest) qctl selftest ;;
    help|-h|--help) usage ;;
    *) echo "unknown command: $cmd" >&2; usage >&2; exit 2 ;;
esac