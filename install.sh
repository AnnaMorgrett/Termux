#!/data/data/com.termux/files/usr/bin/bash
# ═══════════════════════════════════════════════════════════════════════
#  Termux Media Pipeline 1-Click Installer
#  Repository: https://github.com/AnnaMorgrett/Termux
# ═══════════════════════════════════════════════════════════════════════
set -eu

readonly REPO_URL="https://github.com/AnnaMorgrett/Termux.git"
readonly TARGET_DIR="/storage/emulated/0/Termux"

echo "=================================================="
echo "  Termux Media Pipeline — Automated Setup"
echo "=================================================="

# ── 1. Android Storage Permissions ────────────────────────────────────
echo "[1/5] Requesting Android storage permissions..."
if [ ! -d ~/storage ]; then termux-setup-storage; sleep 4; fi

# Block until storage permission is granted and /storage/emulated/0 is writable
while [ ! -d "/storage/emulated/0" ] || [ ! -w "/storage/emulated/0" ]; do
    echo "[!] Waiting for storage access... Tap 'Allow' on your device screen."
    sleep 2
done
echo "[✓] Storage permission active."

# ── 2. Update Packages & Install Dependencies ────────────────────────
echo "[2/5] Updating packages and installing dependencies..."
pkg update -y
pkg install -y git ffmpeg python python-pip

# Ensure yt-dlp is present
if ! command -v yt-dlp &>/dev/null; then
    echo "[*] Installing yt-dlp via pip..."
    pip install --upgrade yt-dlp
fi
echo "[✓] Dependencies installed."

# ── 3. Clone or Update Repository ─────────────────────────────────────
echo "[3/5] Setting up pipeline scripts in $TARGET_DIR..."
if [ -d "$TARGET_DIR/.git" ]; then
    echo "[*] Existing repo detected. Pulling latest updates..."
    git -C "$TARGET_DIR" pull --ff-only || {
        echo "[!] Fast-forward pull failed. Fetching and resetting to origin/main..."
        git -C "$TARGET_DIR" fetch origin
        git -C "$TARGET_DIR" reset --hard origin/main
    }
else
    mkdir -p "$(dirname "$TARGET_DIR")"
    git clone "$REPO_URL" "$TARGET_DIR"
fi
echo "[✓] Repository synchronized."

# ── 4. Generate Global Shortcuts ──────────────────────────────────────
echo "[4/5] Generating global shortcuts in $PREFIX/bin/..."

# 'tiktok' shortcut
cat << 'EOF' > "$PREFIX/bin/tiktok"
#!/data/data/com.termux/files/usr/bin/bash
exec bash /storage/emulated/0/Termux/master_run.sh "$@"
EOF

# 'dl' shortcut
cat << 'EOF' > "$PREFIX/bin/dl"
#!/data/data/com.termux/files/usr/bin/bash
set -eu

if [ $# -lt 1 ]; then
    echo "Usage: dl <URL> [extra yt-dlp options...]" >&2
    exit 1
fi

bash /storage/emulated/0/Termux/download.sh "$@"
exec bash /storage/emulated/0/Termux/master_run.sh
EOF

echo "[✓] Shortcuts created: 'dl' and 'tiktok'."

# ── 5. Set Execution Permissions ──────────────────────────────────────
echo "[5/5] Applying execution permissions..."
chmod +x "$TARGET_DIR"/*.sh
chmod +x "$PREFIX/bin/tiktok" "$PREFIX/bin/dl"
echo "[✓] Permissions granted."

echo "=================================================="
echo "  Setup Complete!"
echo "  - Run 'dl <URL>' to download and process."
echo "  - Run 'tiktok' to process existing media folders."
echo "=================================================="
