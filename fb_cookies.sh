#!/usr/bin/env bash
# fb_cookies.sh - optional Facebook cookie handling for download.sh (sourced).
# Root is OPTIONAL: without it everything here degrades gracefully.

FB_COOKIES="${FB_COOKIES:-$HOME/fb_cookies.txt}"
FB_COOKIE_MAX_AGE_H="${FB_COOKIE_MAX_AGE_H:-6}"
FB_BROWSER_PKGS="${FB_BROWSER_PKGS:-org.mozilla.fennec_fdroid org.mozilla.firefox org.mozilla.firefox_beta org.mozilla.fenix org.mozilla.fennec_aurora}"

_fb_su() { su -mm -c "$1" 2>/dev/null || su -c "$1" 2>/dev/null; }

fb_has_root() {
    command -v su &>/dev/null || return 1
    timeout 10 su -c 'id -u' 2>/dev/null | grep -qx 0
}

fb_cookies_fresh() {
    [[ -s "$FB_COOKIES" ]] || return 1
    local now mtime
    now=$(date +%s); mtime=$(stat -c %Y "$FB_COOKIES" 2>/dev/null) || return 1
    (( now - mtime < FB_COOKIE_MAX_AGE_H * 3600 ))
}

fb_refresh_cookies() {
    local url="$1" tmp uid gid pkg prof found=""
    if ! fb_has_root; then
        printf "${C_YELLOW:-}[~] No root: skipping browser cookie refresh.${C_RESET:-}\n"
        return 1
    fi
    for pkg in $FB_BROWSER_PKGS; do
        prof=$(_fb_su "find /data/user/0/$pkg/files/mozilla -maxdepth 2 -name cookies.sqlite" | head -1)
        [[ -n "$prof" ]] && { found="$(dirname "$prof")"; break; }
    done
    if [[ -z "$found" ]]; then
        printf "${C_YELLOW:-}[~] No Firefox-family browser profile found; skipping cookie refresh.${C_RESET:-}\n"
        return 1
    fi
    uid=$(id -u); gid=$(id -g)
    tmp=$(mktemp -d "${TMPDIR:-$HOME}/.fbprof.XXXXXX") || return 1
    if ! _fb_su "cp '$found'/cookies.sqlite* '$tmp'/ && chown -R $uid:$gid '$tmp' && chmod -R u+rw '$tmp'"; then
        rm -rf "$tmp"
        printf "${C_YELLOW:-}[~] Could not copy browser cookies; skipping refresh.${C_RESET:-}\n"
        return 1
    fi
    printf "${C_BLUE:-}[*] Refreshing Facebook cookies from browser...${C_RESET:-}\n"
    local raw="$FB_COOKIES.raw.$$" new="$FB_COOKIES.new.$$"
    rm -f "$raw" "$new"
    yt-dlp --cookies-from-browser "firefox:$tmp" --cookies "$raw" \
           --skip-download --no-playlist -q --no-warnings \
           $(python3 -c 'import curl_cffi' 2>/dev/null && echo --impersonate firefox) \
           "$url" </dev/null >/dev/null 2>&1
    rm -rf "$tmp"
    if [[ -s "$raw" ]]; then
        awk -F'\t' '/^# /{print;next} $1 ~ /(facebook|fb)\.com$/' "$raw" > "$new"
    fi
    rm -f "$raw"
    if [[ -s "$new" ]] && grep -q -E $'\tc_user\t' "$new" && grep -q -E $'\txs\t' "$new"; then
        chmod 600 "$new"; mv -f "$new" "$FB_COOKIES"
        printf "${C_GREEN:-}[✓] Facebook cookies refreshed.${C_RESET:-}\n"
        return 0
    fi
    rm -f "$new"
    printf "${C_YELLOW:-}[~] Browser has no Facebook login; keeping existing cookies.${C_RESET:-}\n"
    return 1
}

# Fills the global array site_args for the given URL.
fb_site_args() {
    local url="$1"
    site_args=()
    case "$url" in
        *facebook.com*|*fb.watch*|*fb.com*) ;;
        *) return 0 ;;
    esac
    fb_cookies_fresh || fb_refresh_cookies "$url" || true
    [[ -s "$FB_COOKIES" ]] && site_args+=(--cookies "$FB_COOKIES")
    if python3 -c 'import curl_cffi' 2>/dev/null; then
        site_args+=(--impersonate firefox)
    else
        printf "${C_YELLOW:-}[~] curl_cffi missing: pip install curl_cffi --break-system-packages${C_RESET:-}\n"
    fi
    return 0
}
