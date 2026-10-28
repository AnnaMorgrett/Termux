#!/usr/bin/env bash
# shortcuts.sh - (re)creates the global commands: dl, tiktok, q   (safe to run many times)
set -eu
TARGET_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d "/data/data/com.termux" || -n "${TERMUX_VERSION:-}" ]]; then
    BIN_DIR="${BIN_DIR:-${PREFIX:-/data/data/com.termux/files/usr}/bin}"
else
    BIN_DIR="${BIN_DIR:-${PREFIX:-$HOME/.local/bin}}"
fi
mkdir -p "$BIN_DIR"
printf '#!/usr/bin/env bash\nexec bash "%s/master_run.sh" "$@"\n' "$TARGET_DIR" > "$BIN_DIR/tiktok"
printf '#!/usr/bin/env bash\nexec bash "%s/q.sh" dl "$@"\n'        "$TARGET_DIR" > "$BIN_DIR/dl"
printf '#!/usr/bin/env bash\nexec bash "%s/q.sh" "$@"\n'           "$TARGET_DIR" > "$BIN_DIR/q"
# ── Share-to-Termux handlers (~/bin) and Tasker scripts (~/.termux/tasker) ─────
H="${HOME:-/data/data/com.termux/files/home}"
MARK="# media-queue share handler"
put() {   # put FILE CONTENT : writes an executable script; a foreign file is kept as .bak
    if [[ -f "$1" ]] && ! grep -q "$MARK" "$1" 2>/dev/null; then mv -f "$1" "$1.bak.$(date +%Y%m%d%H%M%S)"; echo "Kept your old $(basename "$1") as $1.bak.*"; fi
    printf '#!/usr/bin/env bash\n%s\n%s\n' "$MARK" "$2" > "$1"; chmod 700 "$1"
}
mkdir -p "$H/bin" "$H/.termux/tasker"
put "$H/bin/termux-url-opener"  "exec bash \"$TARGET_DIR/share_handler.sh\" url \"\${1:-}\""
put "$H/bin/termux-file-editor" "exec bash \"$TARGET_DIR/share_handler.sh\" files \"\$@\""
put "$H/.termux/tasker/media-queue-run.sh"  "exec bash \"$TARGET_DIR/master_run.sh\""
put "$H/.termux/tasker/media-queue-ui.sh"   "exec bash \"$TARGET_DIR/q.sh\" ui open"
put "$H/.termux/tasker/media-queue-stop.sh" "exec bash \"$TARGET_DIR/q.sh\" stop"

chmod +x "$BIN_DIR/tiktok" "$BIN_DIR/dl" "$BIN_DIR/q" "$TARGET_DIR"/*.sh 2>/dev/null || true
echo "Shortcuts ready in $BIN_DIR: dl, tiktok, q   |  Share handlers in $H/bin   |  Tasker scripts in $H/.termux/tasker"
