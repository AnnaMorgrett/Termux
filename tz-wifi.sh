#!/system/bin/sh
# tz-wifi.sh - set timezone + Wi-Fi country code on every boot (needs root)
#   KernelSU/Magisk : copy to /data/adb/service.d/ and chmod 755
#   Termux:Boot     : copy to ~/.termux/boot/ and chmod +x
#   Manual test     : su -c "sh /path/to/tz-wifi.sh"
# Log: /data/local/tmp/tz-wifi.log

TZ_NAME="Asia/Jakarta"
WIFI_CC="US"
LOG=/data/local/tmp/tz-wifi.log

export PATH="$PATH:/system/bin:/system/xbin:/vendor/bin"

# Started as the Termux user? Re-run this same file through su.
[ "$(id -u)" = 0 ] || exec su -c "sh $(readlink -f "$0")"

# Keep the log small, then send all output to it.
[ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 51200 ] && : > "$LOG"
exec >> "$LOG" 2>&1
echo "=== $(date) ==="

# Wait (max ~4 min) until Android has finished booting.
n=0
while [ "$(getprop sys.boot_completed)" != 1 ] && [ "$n" -lt 120 ]; do
  sleep 2
  n=$((n + 1))
done
sleep 5

# --- Timezone ---
settings put global auto_time_zone 0   # stop auto/network zone from overriding
setprop persist.sys.timezone "$TZ_NAME"
cmd alarm set-timezone "$TZ_NAME" || service call alarm 3 s16 "$TZ_NAME"
echo "timezone: $(getprop persist.sys.timezone)"

# --- Wi-Fi country code (retry, the Wi-Fi stack can be late) ---
for n in 1 2 3; do
  cmd wifi force-country-code enabled "$WIFI_CC" && break
  sleep 10
done
echo "wifi country: $(cmd wifi get-country-code 2>&1)"
