#!/usr/bin/env bash
# shortcuts.sh - Registers CLI shortcuts (tiktok, dl, q) and Android Share handlers.
set -eu

readonly TARGET_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly BIN_DIR="${BIN_DIR:-${PREFIX:-/data/data/com.termux/files/usr}/bin}"
readonly H="${HOME:-/data/data/com.termux/files/home}"
readonly MARK="# media-queue share handler"

mkdir -p "$BIN_DIR" "$H/bin"

printf '#!/usr/bin/env bash\nexec bash "%s/master_run.sh" "$@"\n' "$TARGET_DIR" > "$BIN_DIR/tiktok"
printf '#!/usr/bin/env bash\nexec bash "%s/q.sh" dl "$@"\n'        "$TARGET_DIR" > "$BIN_DIR/dl"
printf '#!/usr/bin/env bash\nexec bash "%s/q.sh" "$@"\n'           "$TARGET_DIR" > "$BIN_DIR/q"

put_hook() {
    local dest="$1" body="$2"
    if [[ -f "$dest" ]] && ! grep -q "$MARK" "$dest" 2>/dev/null; then
        mv -f "$dest" "${dest}.bak.$(date +%Y%m%d%H%M%S)"
    fi
    printf '#!/usr/bin/env bash\n%s\n%s\n' "$MARK" "$body" > "$dest"
    chmod 700 "$dest"
}

put_hook "$H/bin/termux-url-opener"  "exec bash \"$TARGET_DIR/share_handler.sh\" url \"\${1:-}\""
put_hook "$H/bin/termux-file-editor" "exec bash \"$TARGET_DIR/share_handler.sh\" files \"\$@\""

chmod +x "$BIN_DIR/tiktok" "$BIN_DIR/dl" "$BIN_DIR/q" "$TARGET_DIR"/*.sh "$TARGET_DIR"/*.py 2>/dev/null || true
echo "Shortcuts ready: tiktok, dl, q | Android Share hooks ready in $H/bin"