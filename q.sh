#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  @file        q.sh   (installed as the `q` command)
#  @brief       Front end for the persistent job queue.
#  @version     1.0.0
# ═══════════════════════════════════════════════════════════════════════════════
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUEUE_DIR="${QUEUE_DIR:-$SCRIPT_DIR/data/queue}"; export QUEUE_DIR
PY="${PYTHON:-python3}"
LOG="$SCRIPT_DIR/media_processor_log.txt"
if [[ -d "/data/data/com.termux" || -n "${TERMUX_VERSION:-}" ]]; then SD="${MEDIA_DIR:-/storage/emulated/0}"; else SD="${MEDIA_DIR:-$HOME/TermuxMedia}"; fi
qctl() { "$PY" "$SCRIPT_DIR/qctl.py" "$@"; }

usage() { cat <<'U'
q add [--consume] <url|file>...  queue links or local video files, process in background
q dl <url> [yt-dlp opts] queue one link and wait for it (this is what `dl` does)
q scan                  queue videos found in the TikTok / yt-dlp folders
q run                   run the worker now (foreground)
q bg                    start the worker in the background
q stop                  stop after the current job
q list [status]         pending | running | done | failed
q stats                 counts + worker state
q retry [ID|all]        retry failed jobs
q remove ID             delete a job (not a running one)
q clear [done|failed|all]
q logs [N]              last N log lines (default 30)
q ui [start|stop|status|open]  web page for queue, status, logs and settings
q selftest              check that the queue works on this storage (safe, cleans up)
q percent [0-100]       show / set the audio peak target (0 = -9.0 dB ... 100 = -0.1 dB)
U
}

worker_running() { local p; p=$(cat "$QUEUE_DIR/.worker.lock/pid" 2>/dev/null); [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null; }
start_bg() {
    worker_running && return 0
    mkdir -p "$QUEUE_DIR"
    if [[ -f "$QUEUE_DIR/worker.out" ]] && (( $(stat -c %s "$QUEUE_DIR/worker.out" 2>/dev/null || echo 0) > 262144 )); then : > "$QUEUE_DIR/worker.out"; fi
    nohup bash "$SCRIPT_DIR/worker.sh" >> "$QUEUE_DIR/worker.out" 2>&1 < /dev/null &
    disown 2>/dev/null || true
    echo "worker started in background"
}

FILE_EXTRA=()   # extra qctl options for FILE items (set by: q add --consume ...)
# add_one ITEM -> prints a line, sets ADD_RC (0 queued, 3 duplicate, 2 bad)
add_one() {
    local it="$1" u f
    ADD_RC=0
    if [[ "$it" =~ ^https?://[^[:space:]]+$ ]]; then
        qctl add --url "$it" "${@:2}"; ADD_RC=$?; return
    fi
    if [[ -e "$it" || "$it" == /* ]]; then
        f="$it"
        [[ "$f" == /* ]] || f="$(cd "$(dirname "$f")" 2>/dev/null && pwd)/$(basename "$f")"
        qctl add --file "$f" "${FILE_EXTRA[@]}"; ADD_RC=$?; return
    fi
    u=$(printf '%s' "$it" | grep -oE 'https?://[^[:space:]]+' | head -1)   # link inside shared text
    if [[ -n "$u" ]]; then qctl add --url "$u" "${@:2}"; ADD_RC=$?; return; fi
    echo "not a link or file: $it" >&2; ADD_RC=2
}

scan_folders() {
    local dir f age queued=0 dup=0 out
    for dir in "$SD/DCIM/TikTok" "$SD/Download/yt-dlp"; do
        [[ -d "$dir" ]] || continue
        while IFS= read -r -d '' f <&3; do
            age=$(( $(date +%s) - $(stat -c %Y "$f" 2>/dev/null || echo 0) ))
            (( age >= 0 && age < 5 )) && sleep $(( 5 - age ))      # still being written
            out=$(qctl add --file "$f" --consume 2>&1); case $? in
                0) (( ++queued )) ;;
                3) (( ++dup )) ;;
                *) echo "[!] Could not queue files: $out" >&2; echo "    Nothing was changed or deleted. Run: q selftest" >&2; return 1 ;;   # stop: same error for every file
            esac
        done 3< <(find "$dir" -maxdepth 1 -type f \( -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.webm' \
                   -o -iname '*.mov' -o -iname '*.avi' -o -iname '*.3gp' -o -iname '*.ts' -o -iname '*.flv' -o -iname '*.m4v' \) \
                   ! -regex '.*\.f[0-9]+\.[A-Za-z0-9]+$' -print0 2>/dev/null)
    done
    echo "folder scan: queued=$queued already_queued=$dup"
}

ui_pidfile() { echo "$(dirname "$QUEUE_DIR")/webui.pid"; }
ui_running() {
    local p; p=$(cat "$(ui_pidfile)" 2>/dev/null)
    [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null && { [[ ! -r "/proc/$p/cmdline" ]] || tr '\0' ' ' < "/proc/$p/cmdline" | grep -q webui.py; }
}
ui_url() { echo "http://${WEBUI_URL_HOST:-127.0.0.1}:${WEBUI_PORT:-8787}"; }
ui_cmd() {
    local sub="${1:-start}" pidf out p i
    pidf="$(ui_pidfile)"; out="$(dirname "$QUEUE_DIR")/webui.out"
    case "$sub" in
        start|open)
            if ui_running; then echo "Web UI already running: $(ui_url)"
            else
                mkdir -p "$(dirname "$QUEUE_DIR")"
                [[ -f "$out" ]] && (( $(stat -c %s "$out" 2>/dev/null || echo 0) > 65536 )) && : > "$out"
                nohup "$PY" "$SCRIPT_DIR/webui.py" >> "$out" 2>&1 < /dev/null &
                echo $! > "$pidf"; disown 2>/dev/null || true
                for i in 1 2 3 4 5 6 7 8 9 10; do sleep 0.3; ui_running && (echo > "/dev/tcp/127.0.0.1/${WEBUI_PORT:-8787}") 2>/dev/null && break; done
                if ui_running; then echo "Web UI started: $(ui_url)"; else echo "Web UI failed to start. Last lines:" >&2; tail -n 5 "$out" >&2; return 1; fi
            fi
            [[ "$sub" == "open" ]] && command -v termux-open-url &>/dev/null && termux-open-url "$(ui_url)" ;;
        stop)   if ui_running; then kill "$(cat "$pidf")" 2>/dev/null; rm -f "$pidf"; echo "Web UI stopped"; else echo "Web UI is not running"; fi ;;
        status) ui_running && echo "Web UI running: $(ui_url)" || echo "Web UI not running" ;;
        *) usage >&2; return 2 ;;
    esac
}

cmd="${1:-help}"; [[ $# -gt 0 ]] && shift
case "$cmd" in
    add)
        [[ "${1:-}" == "--consume" ]] && { FILE_EXTRA=(--consume); shift; }   # delete files after a verified result
        [[ $# -ge 1 ]] || { usage >&2; exit 2; }
        bad=0; for it in "$@"; do add_one "$it"; [[ $ADD_RC == 2 ]] && bad=1; done
        [[ "${Q_NO_BG:-}" == "1" ]] || start_bg
        exit $bad ;;
    dl)
        [[ $# -ge 1 ]] || { echo "Usage: dl <URL> [extra yt-dlp options...]" >&2; exit 1; }
        url="$1"; shift; extra=(); for o in "$@"; do extra+=("--arg=$o"); done
        add_one "$url" "${extra[@]}"; [[ $ADD_RC == 2 ]] && exit 2
        exec bash "$SCRIPT_DIR/worker.sh" ;;
    scan)  scan_folders ;;
    run)   exec bash "$SCRIPT_DIR/worker.sh" ;;
    bg)    start_bg ;;
    stop)  if worker_running; then mkdir -p "$QUEUE_DIR"; : > "$QUEUE_DIR/.stop"; echo "stop requested (after the current job)"; else echo "no worker running"; fi ;;
    list)  qctl list ${1:+--status "$1"} ;;
    stats|status) echo "$(qctl stats)  worker=$(worker_running && echo running || echo idle)" ;;
    retry) if [[ "${1:-all}" == "all" ]]; then qctl retry --all; else qctl retry "$1"; fi; [[ $? == 0 ]] && { [[ "${Q_NO_BG:-}" == "1" ]] || start_bg; } ;;
    remove) [[ $# -ge 1 ]] || { usage >&2; exit 2; }; qctl remove "$1" ;;
    clear) case "${1:-done}" in all) qctl clear done failed ;; done|failed) qctl clear "$1" ;; *) usage >&2; exit 2 ;; esac ;;
    logs)  tail -n "${1:-30}" "$LOG" 2>/dev/null ;;
    ui)    ui_cmd "$@" ;;
    selftest) qctl selftest ;;
    percent)
        "$PY" - "$SCRIPT_DIR" "${1:-}" <<'PYEOF'
import os, sys
sys.path.insert(0, sys.argv[1]); os.environ.setdefault("QUEUE_DIR", os.path.join(sys.argv[1], "data", "queue"))
import webui
cur = webui.read_config().get("PEAK_PERCENT", webui.SCHEMA["PEAK_PERCENT"][0])
def show(v): print("PEAK_PERCENT = %s%%  ->  target peak %.3f dB   (0%% = -9.0 dB, 50%% = -4.55 dB, 100%% = -0.1 dB)" % (v, -9 + 8.9 * float(v) / 100))
if not sys.argv[2]:
    show(cur)
else:
    try: v = webui.validate("PEAK_PERCENT", sys.argv[2])
    except ValueError as e: print("Not changed: %s" % e, file=sys.stderr); sys.exit(2)
    c = webui.read_config()
    if v == webui.SCHEMA["PEAK_PERCENT"][0]: c.pop("PEAK_PERCENT", None)
    else: c["PEAK_PERCENT"] = v
    webui.write_config(c); print("Saved. Applies from the next file."); show(v)
PYEOF
        ;;
    help|-h|--help) usage ;;
    *) echo "unknown command: $cmd" >&2; usage >&2; exit 2 ;;
esac
