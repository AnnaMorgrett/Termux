#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  @file        install.sh
#  @brief       Automated installer for Android (Termux) & Desktop (Linux/macOS/Git Bash).
#  @author      Anna Morgrett (https://github.com/AnnaMorgrett/Termux)
#  @license     MIT
#  @version     2.1.0
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

# ── Color Output (ANSI) ───────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    C_BLUE='\033[0;34m'
    C_GREEN='\033[0;32m'
    C_YELLOW='\033[0;33m'
    C_RED='\033[0;31m'
    C_BOLD='\033[1m'
    C_RESET='\033[0m'
else
    C_BLUE='' C_GREEN='' C_YELLOW='' C_RED='' C_BOLD='' C_RESET=''
fi

readonly REPO_URL="https://github.com/AnnaMorgrett/Termux.git"
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

printf "${C_BOLD}==================================================${C_RESET}\n"
printf "${C_BOLD}  Media Pipeline Installer (Termux & PC)          ${C_RESET}\n"
printf "${C_BOLD}==================================================${C_RESET}\n"

# ── 1. Detect Environment ─────────────────────────────────────────────────────
if [[ -d "/data/data/com.termux" || -n "${TERMUX_VERSION:-}" ]]; then
    IS_TERMUX=true
    TARGET_DIR="/storage/emulated/0/Termux"
    BIN_DIR="${PREFIX:-/data/data/com.termux/files/usr}/bin"
    SD="${MEDIA_DIR:-/storage/emulated/0}"
    printf "${C_BLUE}[*] Target Environment:${C_RESET} Android (Termux)\n"
else
    IS_TERMUX=false
    TARGET_DIR="${CURRENT_DIR}"
    BIN_DIR="${PREFIX:-$HOME/.local/bin}"
    SD="${MEDIA_DIR:-$HOME/TermuxMedia}"
    printf "${C_BLUE}[*] Target Environment:${C_RESET} PC / Desktop Linux / Git Bash\n"
fi

# ── 2. Storage Setup & Permissions ────────────────────────────────────────────
if [[ "$IS_TERMUX" == true ]]; then
    printf "${C_BLUE}[1/4] Configuring Android storage permissions...${C_RESET}\n"
    if [[ ! -d "$HOME/storage" ]]; then
        termux-setup-storage
        printf "${C_YELLOW}[!] Please tap 'Allow' on the Android permission popup...${C_RESET}\n"
        while [[ ! -d "/storage/emulated/0" || ! -w "/storage/emulated/0" ]]; do
            sleep 2
        done
    fi
    printf "${C_GREEN}[✓] Android shared storage is accessible.${C_RESET}\n"
else
    printf "${C_BLUE}[1/4] Initializing PC storage workspace in %s...${C_RESET}\n" "$SD"
    mkdir -p "$SD/DCIM/TikTok" \
             "$SD/Download/yt-dlp" \
             "$SD/Pictures/TikTok_Assets" \
             "$SD/Movies/NormalizedVideo" \
             "$SD/Documents"
    printf "${C_GREEN}[✓] Workspace folders initialized.${C_RESET}\n"
fi

# ── 3. Package & Dependency Check ─────────────────────────────────────────────
printf "${C_BLUE}[2/4] Verifying binary dependencies...${C_RESET}\n"
if [[ "$IS_TERMUX" == true ]]; then
    pkg update -y
    pkg install -y git ffmpeg python python-pip
    if ! command -v yt-dlp &>/dev/null; then
        pip install --upgrade yt-dlp
    fi
else
    for cmd in ffmpeg ffprobe; do
        if ! command -v "$cmd" &>/dev/null; then
            printf "${C_YELLOW}[!] Warning: '%s' is not in PATH. Please install FFmpeg using your package manager.${C_RESET}\n" "$cmd"
        fi
    done
    if ! command -v yt-dlp &>/dev/null; then
        printf "${C_BLUE}[*] Installing yt-dlp via pip...${C_RESET}\n"
        pip install --upgrade yt-dlp 2>/dev/null || python3 -m pip install --upgrade yt-dlp 2>/dev/null || true
    fi
fi
printf "${C_GREEN}[✓] Binary dependencies checked.${C_RESET}\n"

# ── 4. Synchronize Repository ─────────────────────────────────────────────────
printf "${C_BLUE}[3/4] Preparing pipeline scripts in %s...${C_RESET}\n" "$TARGET_DIR"
if [[ "$IS_TERMUX" == true ]]; then
    if [[ -d "$TARGET_DIR/.git" ]]; then
        printf "${C_BLUE}[*] Existing repository detected. Pulling updates...${C_RESET}\n"
        git -C "$TARGET_DIR" pull --ff-only 2>/dev/null || {
            git -C "$TARGET_DIR" fetch origin
            git -C "$TARGET_DIR" reset --hard origin/main
        }
    else
        mkdir -p "$(dirname "$TARGET_DIR")"
        git clone "$REPO_URL" "$TARGET_DIR"
    fi
fi
printf "${C_GREEN}[✓] Scripts synchronized.${C_RESET}\n"

# ── 5. Generate Global 'dl' and 'tiktok' Shortcuts ───────────────────────────
printf "${C_BLUE}[4/4] Generating global shortcuts in %s...${C_RESET}\n" "$BIN_DIR"
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

chmod +x "$TARGET_DIR"/*.sh 2>/dev/null || true
chmod +x "$BIN_DIR/tiktok" "$BIN_DIR/dl"

printf "${C_GREEN}[✓] Shortcuts successfully registered: 'dl' and 'tiktok'.${C_RESET}\n"

if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    printf "\n${C_YELLOW}--------------------------------------------------${C_RESET}\n"
    printf "${C_YELLOW}  NOTE: %s is not currently in your PATH.${C_RESET}\n" "$BIN_DIR"
    printf "  Add it to your profile (e.g., ~/.bashrc or ~/.zshrc):\n"
    printf "    export PATH=\"%s:\$PATH\"\n" "$BIN_DIR"
    printf "${C_YELLOW}--------------------------------------------------${C_RESET}\n"
fi

printf "\n${C_BOLD}==================================================${C_RESET}\n"
printf "${C_BOLD}  Installation Complete!                         ${C_RESET}\n"
printf "  - Run ${C_GREEN}dl <URL>${C_RESET} to download and normalize.\n"
printf "  - Run ${C_GREEN}tiktok${C_RESET} to batch process existing media.\n"
printf "${C_BOLD}==================================================${C_RESET}\n"
