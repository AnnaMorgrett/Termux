#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  Termux & PC Media Pipeline 1-Click Installer
#  Repository: https://github.com/AnnaMorgrett/Termux
# ═══════════════════════════════════════════════════════════════════════
set -eu

readonly REPO_URL="https://github.com/AnnaMorgrett/Termux.git"
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=================================================="
echo "  Media Pipeline Installer (Termux & PC)"
echo "=================================================="

# ── 1. Detect Environment ─────────────────────────────────────────────
if [ -d "/data/data/com.termux" ] || [ -n "${TERMUX_VERSION:-}" ]; then
    IS_TERMUX=true
    TARGET_DIR="/storage/emulated/0/Termux"
    BIN_DIR="${PREFIX:-/data/data/com.termux/files/usr}/bin"
    SD="${MEDIA_DIR:-/storage/emulated/0}"
    echo "[*] Environment detected: Android (Termux)"
else
    IS_TERMUX=false
    TARGET_DIR="${CURRENT_DIR}"
    # Prefer $PREFIX if set, else ~/.local/bin or ~/bin
    BIN_DIR="${PREFIX:-$HOME/.local/bin}"
    SD="${MEDIA_DIR:-$HOME/TermuxMedia}"
    echo "[*] Environment detected: PC / Desktop Linux / Git Bash"
fi

# ── 2. Storage Setup & Permissions ────────────────────────────────────
if [ "$IS_TERMUX" = true ]; then
    echo "[1/4] Checking Termux storage permissions..."
    if [ ! -d "$HOME/storage" ]; then
        termux-setup-storage
        echo "[!] Waiting for storage permission... Tap 'Allow' on your device screen."
        while [ ! -d "/storage/emulated/0" ] || [ ! -w "/storage/emulated/0" ]; do
            sleep 2
        done
    fi
    echo "[✓] Storage permission active."
else
    echo "[1/4] Setting up PC workspace folders in $SD..."
    mkdir -p "$SD/DCIM/TikTok" \
             "$SD/Download/yt-dlp" \
             "$SD/Pictures/TikTok_Assets" \
             "$SD/Movies/NormalizedVideo" \
             "$SD/Documents"
    echo "[✓] PC workspace folders initialized."
fi

# ── 3. Package & Dependency Check ─────────────────────────────────────
echo "[2/4] Verifying dependencies..."
if [ "$IS_TERMUX" = true ]; then
    pkg update -y
    pkg install -y git ffmpeg python python-pip
    if ! command -v yt-dlp &>/dev/null; then
        pip install --upgrade yt-dlp
    fi
else
    # PC environment dependency verification
    for cmd in ffmpeg ffprobe python3; do
        if ! command -v "$cmd" &>/dev/null && ! command -v "${cmd%.*}" &>/dev/null; then
            echo "[!] WARNING: '$cmd' is not in PATH. Please install it using your system package manager."
        fi
    done
    if ! command -v yt-dlp &>/dev/null; then
        echo "[*] Installing yt-dlp via pip..."
        pip install --upgrade yt-dlp 2>/dev/null || python3 -m pip install --upgrade yt-dlp 2>/dev/null || true
    fi
fi
echo "[✓] Dependencies verified."

# ── 4. Synchronize Repository ─────────────────────────────────────────
echo "[3/4] Ensuring scripts are present in $TARGET_DIR..."
if [ "$IS_TERMUX" = true ]; then
    if [ -d "$TARGET_DIR/.git" ]; then
        echo "[*] Existing repo detected. Pulling latest updates..."
        git -C "$TARGET_DIR" pull --ff-only 2>/dev/null || {
            git -C "$TARGET_DIR" fetch origin
            git -C "$TARGET_DIR" reset --hard origin/main
        }
    else
        mkdir -p "$(dirname "$TARGET_DIR")"
        git clone "$REPO_URL" "$TARGET_DIR"
    fi
fi
echo "[✓] Scripts ready."

# ── 5. Generate Global 'dl' and 'tiktok' Shortcuts ───────────────────
echo "[4/4] Registering global shortcuts in $BIN_DIR..."
mkdir -p "$BIN_DIR"

# 'tiktok' shortcut
cat << EOF > "$BIN_DIR/tiktok"
#!/usr/bin/env bash
exec bash "$TARGET_DIR/master_run.sh" "\$@"
EOF

# 'dl' shortcut
cat << EOF > "$BIN_DIR/dl"
#!/usr/bin/env bash
set -eu
if [ \$# -lt 1 ]; then
    echo "Usage: dl <URL> [extra yt-dlp options...]" >&2
    exit 1
fi
bash "$TARGET_DIR/download.sh" "\$@"
exec bash "$TARGET_DIR/master_run.sh"
EOF

# Grant execute permissions
chmod +x "$TARGET_DIR"/*.sh 2>/dev/null || true
chmod +x "$BIN_DIR/tiktok" "$BIN_DIR/dl"

echo "[✓] Shortcuts created: 'dl' and 'tiktok'."

# Check if BIN_DIR is in PATH for PC users
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    echo "--------------------------------------------------"
    echo "  NOTE: $BIN_DIR is not yet in your PATH."
    echo "  Add it to your ~/.bashrc or ~/.zshrc:"
    echo "    export PATH=\"$BIN_DIR:\$PATH\""
    echo "--------------------------------------------------"
fi

echo "=================================================="
echo "  Setup Complete!"
echo "  - dl <URL> : Download media and trigger normalization"
echo "  - tiktok   : Process media folders immediately"
echo "=================================================="
