#!/usr/bin/env bash
# install.sh - Termux-only automated installer (zero root, zero Termux:API).
set -euo pipefail

if [[ -t 1 ]]; then
    C_BLUE='\033[0;34m' C_GREEN='\033[0;32m' C_YELLOW='\033[0;33m' C_RED='\033[0;31m' C_BOLD='\033[1m' C_RESET='\033[0m'
else
    C_BLUE='' C_GREEN='' C_YELLOW='' C_RED='' C_BOLD='' C_RESET=''
fi

if [[ ! -d "/data/data/com.termux" && -z "${TERMUX_VERSION:-}" ]]; then
    printf "${C_RED}[ERROR] This pipeline supports Android Termux only.${C_RESET}\n" >&2
    exit 1
fi

readonly REPO_URL="https://github.com/AnnaMorgrett/Termux.git"
readonly TARGET_DIR="/storage/emulated/0/Termux"
BIN_DIR="${PREFIX:-/data/data/com.termux/files/usr}/bin"

printf "${C_BOLD}==================================================${C_RESET}\n"
printf "${C_BOLD}  Termux Media Pipeline Installer                 ${C_RESET}\n"
printf "${C_BOLD}==================================================${C_RESET}\n"

# 1. Shared storage access
printf "${C_BLUE}[1/4] Verifying shared storage permissions...${C_RESET}\n"
if [[ ! -d "$HOME/storage" || ! -w "/storage/emulated/0" ]]; then
    termux-setup-storage
    printf "${C_YELLOW}[!] Grant storage permission on the Android prompt...${C_RESET}\n"
    while [[ ! -w "/storage/emulated/0" ]]; do sleep 2; done
fi
printf "${C_GREEN}[✓] Shared storage ready.${C_RESET}\n"

# 2. Packages & Python dependencies
printf "${C_BLUE}[2/4] Installing Termux dependencies...${C_RESET}\n"
pkg update -y
pkg install -y git ffmpeg python python-pip curl xz-utils file
pip install --upgrade yt-dlp curl_cffi
printf "${C_GREEN}[✓] Core packages installed.${C_RESET}\n"

# 3. Custom ARM64 ByteVC2-capable FFmpeg
install_bvc2_ffmpeg() {
    local prefix="${PREFIX:-/data/data/com.termux/files/usr}"
    local bvc2_dir="$prefix/opt/ffmpeg-bvc2"
    local state_dir="$prefix/var/lib/media-pipeline"
    local state_file="$state_dir/ffmpeg-bvc2-asset-updated"
    local release_json asset_url asset_updated tmp extract src_root backup
    local -a release_info=()

    printf "${C_BLUE}[3/4] Checking ARM64 BVC2 FFmpeg release...${C_RESET}\n"
    if ! release_json="$(curl -fsSL --retry 3 --connect-timeout 20 "https://api.github.com/repos/AnnaMorgrett/ffmpeg-bvc2/releases/tags/latest-arm64")"; then
        printf "${C_YELLOW}[!] GitHub unreachable; keeping existing FFmpeg.${C_RESET}\n"
        return 0
    fi
    mapfile -t release_info < <(python3 -c 'import json,sys; d=json.load(sys.stdin); a=next(x for x in d.get("assets",[]) if x.get("name")=="ffmpeg-bvc2-android-arm64.tar.xz"); print(a["browser_download_url"]); print(a["updated_at"])' <<< "$release_json")
    [[ "${#release_info[@]}" -eq 2 ]] || return 0
    asset_url="${release_info[0]}"; asset_updated="${release_info[1]}"

    if [[ -x "$bvc2_dir/bin/ffmpeg" && -x "$bvc2_dir/bin/ffprobe" && -f "$state_file" && "$(cat "$state_file")" == "$asset_updated" ]] \
        && "$bvc2_dir/bin/ffmpeg" -hide_banner -decoders 2>/dev/null | grep -Eq '[[:space:]]bvc2[[:space:]]'; then
        printf "${C_GREEN}[✓] BVC2 FFmpeg is up to date.${C_RESET}\n"
        return 0
    fi

    tmp="$(mktemp -d "$prefix/tmp/ffmpeg-bvc2.XXXXXX")"
    extract="$tmp/extract"; mkdir -p "$extract"

    if ! curl -fL --retry 3 --connect-timeout 30 "$asset_url" -o "$tmp/ffmpeg-bvc2.tar.xz"; then
        printf "${C_YELLOW}[!] BVC2 download failed; retaining system FFmpeg.${C_RESET}\n"
        rm -rf "$tmp"; return 0
    fi

    if ! tar -xJf "$tmp/ffmpeg-bvc2.tar.xz" -C "$extract"; then
        printf "${C_YELLOW}[!] BVC2 archive extraction failed; retaining system FFmpeg.${C_RESET}\n"
        rm -rf "$tmp"; return 0
    fi

    # Support both flat (bin/ffmpeg) and single-directory nested archives
    if [[ -f "$extract/bin/ffmpeg" ]]; then
        src_root="$extract"
    else
        src_root="$(find "$extract" -mindepth 1 -maxdepth 2 -type f -path '*/bin/ffmpeg' -printf '%h\n' | head -1)"
        src_root="${src_root%/bin}"
    fi

    if [[ -z "$src_root" || ! -f "$src_root/bin/ffmpeg" ]]; then
        printf "${C_YELLOW}[!] BVC2 archive missing bin/ffmpeg; retaining system FFmpeg.${C_RESET}\n"
        rm -rf "$tmp"; return 0
    fi

    chmod +x "$src_root/bin/"* 2>/dev/null || true

    if ! LD_LIBRARY_PATH="$src_root/lib:${LD_LIBRARY_PATH:-}" "$src_root/bin/ffmpeg" -hide_banner -decoders 2>/dev/null | grep -Eq '[[:space:]]bvc2[[:space:]]'; then
        printf "${C_YELLOW}[!] BVC2 binary failed decoder check; retaining system FFmpeg.${C_RESET}\n"
        rm -rf "$tmp"; return 0
    fi

    mkdir -p "$prefix/opt" "$state_dir"
    backup="$bvc2_dir.previous"; rm -rf "$backup"
    [[ -d "$bvc2_dir" ]] && mv "$bvc2_dir" "$backup"
    if mv "$src_root" "$bvc2_dir"; then
        printf "%s\n" "$asset_updated" > "$state_file"
        rm -rf "$backup" "$tmp"
        printf "${C_GREEN}[✓] BVC2 FFmpeg installed.${C_RESET}\n"
    else
        [[ -d "$backup" ]] && mv "$backup" "$bvc2_dir"
        rm -rf "$tmp"
    fi
}
install_bvc2_ffmpeg

# 4. Sync repository & register shortcuts
printf "${C_BLUE}[4/4] Registering shortcuts and Android Share hooks...${C_RESET}\n"
git config --global --replace-all safe.directory "$TARGET_DIR" 2>/dev/null || true
if [[ -d "$TARGET_DIR/.git" ]]; then
    git -C "$TARGET_DIR" pull --ff-only 2>/dev/null || true
else
    mkdir -p "$(dirname "$TARGET_DIR")"
    git clone "$REPO_URL" "$TARGET_DIR"
fi
BIN_DIR="$BIN_DIR" bash "$TARGET_DIR/shortcuts.sh"

printf "\n${C_GREEN}[✓] Setup complete!${C_RESET}\n"
printf "  • Share any link from Facebook/Chrome/TikTok -> Share -> Termux\n"
printf "  • Run ${C_BOLD}tiktok${C_RESET} to process saved TikTok/yt-dlp folders\n"
printf "  • Run ${C_BOLD}dl <URL>${C_RESET} to download and no
rmalize directly\n"
