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
    pkg install -y git ffmpeg python python-pip curl xz-utils
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

# ── 3b. Install the custom ByteVC2-capable FFmpeg (Android ARM64) ─────────────
install_bvc2_ffmpeg() {
    local prefix="${PREFIX:-/data/data/com.termux/files/usr}"
    local bvc2_dir="$prefix/opt/ffmpeg-bvc2"
    local state_dir="$prefix/var/lib/media-pipeline"
    local state_file="$state_dir/ffmpeg-bvc2-asset-updated"
    local release_json asset_url asset_updated tmp stage backup
    local -a release_info=()
    [[ "$IS_TERMUX" == true ]] || return 0
    printf "${C_BLUE}[*] Checking the latest Android ARM64 BVC2 FFmpeg release...${C_RESET}\n"
    if ! release_json="$(curl -fsSL --retry 2 --connect-timeout 15 "https://api.github.com/repos/AnnaMorgrett/ffmpeg-bvc2/releases/tags/latest-arm64")"; then
        printf "${C_YELLOW}[!] Could not reach GitHub Releases; keeping any existing BVC2 build.${C_RESET}\n"; return 0
    fi
    mapfile -t release_info < <(python -c 'import json,sys; d=json.load(sys.stdin); a=next(x for x in d.get("assets",[]) if x.get("name")=="ffmpeg-bvc2-android-arm64.tar.xz"); print(a["browser_download_url"]); print(a["updated_at"])' <<< "$release_json")
    if [[ "${#release_info[@]}" -ne 2 || -z "${release_info[0]}" || -z "${release_info[1]}" ]]; then
        printf "${C_YELLOW}[!] GitHub release has no valid Android ARM64 archive; keeping existing FFmpeg.${C_RESET}\n"; return 0
    fi
    asset_url="${release_info[0]}"; asset_updated="${release_info[1]}"
    if [[ -x "$bvc2_dir/bin/ffmpeg" && -x "$bvc2_dir/bin/ffprobe" && -f "$state_file" && "$(cat "$state_file")" == "$asset_updated" ]] && "$bvc2_dir/bin/ffmpeg" -hide_banner -decoders 2>/dev/null | grep -Eq '[[:space:]]bvc2[[:space:]]'; then
        printf "${C_GREEN}[✓] BVC2 FFmpeg is already current.${C_RESET}\n"; return 0
    fi
    tmp="$(mktemp -d "$prefix/tmp/ffmpeg-bvc2.XXXXXX")" || { printf "${C_YELLOW}[!] Cannot create temporary directory; retaining system FFmpeg.${C_RESET}\n"; return 0; }
    stage="$tmp/stage"; mkdir -p "$stage"
    printf "${C_BLUE}[*] Downloading BVC2-enabled FFmpeg (~25 MB)...${C_RESET}\n"
    if ! curl -fL --retry 2 --connect-timeout 20 "$asset_url" -o "$tmp/ffmpeg-bvc2.tar.xz" || ! tar -xJf "$tmp/ffmpeg-bvc2.tar.xz" -C "$stage" || [[ ! -x "$stage/bin/ffmpeg" || ! -x "$stage/bin/ffprobe" ]] || ! "$stage/bin/ffmpeg" -hide_banner -decoders 2>/dev/null | grep -Eq '[[:space:]]bvc2[[:space:]]'; then
        printf "${C_YELLOW}[!] BVC2 archive validation failed; retaining the existing/system FFmpeg.${C_RESET}\n"; rm -rf "$tmp"; return 0
    fi
    mkdir -p "$prefix/opt" "$state_dir"; backup="$bvc2_dir.previous"; rm -rf "$backup"
    if [[ -d "$bvc2_dir" ]]; then mv "$bvc2_dir" "$backup"; fi
    if mv "$stage" "$bvc2_dir"; then
        printf "%s\n" "$asset_updated" > "$state_file"; rm -rf "$backup" "$tmp"
        printf "${C_GREEN}[✓] BVC2 FFmpeg installed and decoder verified.${C_RESET}\n"
    else
        [[ -d "$backup" ]] && mv "$backup" "$bvc2_dir"; rm -rf "$tmp"
        printf "${C_YELLOW}[!] Could not activate BVC2 FFmpeg; restored the previous build.${C_RESET}\n"
    fi
}
install_bvc2_ffmpeg

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

# Shortcuts (dl, tiktok, q) are generated by shortcuts.sh
BIN_DIR="$BIN_DIR" bash "$TARGET_DIR/shortcuts.sh"

printf "${C_GREEN}[✓] Shortcuts successfully registered: 'dl', 'tiktok' and 'q'.${C_RESET}\n"

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
