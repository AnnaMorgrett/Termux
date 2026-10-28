#!/usr/bin/env bash
# S1a tests for normalize.sh. Needs ffmpeg/ffprobe/python3. Safe: uses a temp dir only.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/scripts" "$T/media/DCIM/TikTok" "$T/media/Download/yt-dlp" "$T/wrap" "$T/fakebin"
cp "$HERE/normalize.sh" "$T/scripts/"
export MEDIA_DIR="$T/media" NORM_MODE=lufs   # these tests cover the LUFS mode; peak mode is covered by s5_peak_test.sh
NORM="$T/scripts/normalize.sh"; LOGF="$T/scripts/media_processor_log.txt"
OUT="$MEDIA_DIR/Movies/NormalizedVideo"
REAL_FFMPEG="$(command -v ffmpeg)"
pass=0; failn=0
ok()   { pass=$((pass+1)); echo "  PASS: $1"; }
bad()  { failn=$((failn+1)); echo "  FAIL: $1"; }
chk()  { if eval "$2"; then ok "$1"; else bad "$1  [$2]"; fi; }

# ffmpeg wrapper for failure injection (FAKE_MODE)
cat > "$T/wrap/ffmpeg" <<W
#!/usr/bin/env bash
real="$REAL_FFMPEG"; a="\$*"
case "\${FAKE_MODE:-}" in
  failcopy)  [[ "\$a" == *"-c:v copy"* && "\$a" == *"-f mp4"* ]] && exit 1 ;;
  failall)   [[ "\$a" == *"-f mp4"* ]] && exit 1 ;;
  truncate)  if [[ "\$a" == *"-c:v copy"* && "\$a" == *"-f mp4"* ]]; then
               "\$real" "\$@" || exit \$?; o="\${@: -1}"; s=\$(stat -c %s "\$o"); truncate -s \$((s*6/10)) "\$o"; exit 0; fi ;;
esac
exec "\$real" "\$@"
W
chmod +x "$T/wrap/ffmpeg"

mk() { # mk NAME VCODEC AUDIO_KIND  (audio: quiet|peaky|none|only)
  local f="$1" vc="$2" ak="$3" ext="${1##*.}"
  local v=(-f lavfi -i "testsrc=size=320x240:rate=25:duration=4")
  local venc=(-c:v "$vc"); [[ "$vc" == libx264 ]] && venc+=(-pix_fmt yuv420p -g 25)
  case "$ak" in
    quiet) "$REAL_FFMPEG" -v error -y "${v[@]}" -f lavfi -i "sine=frequency=440:duration=4,volume=-28dB" "${venc[@]}" -c:a aac -shortest "$f" ;;
    peaky) "$REAL_FFMPEG" -v error -y "${v[@]}" -f lavfi -i "aevalsrc='if(lt(mod(t,1),0.004),0.95*sin(2*PI*1000*t),0.004*sin(2*PI*200*t))':s=44100:d=4" "${venc[@]}" -c:a aac -shortest "$f" ;;
    none)  "$REAL_FFMPEG" -v error -y "${v[@]}" "${venc[@]}" -an "$f" ;;
    only)  "$REAL_FFMPEG" -v error -y -f lavfi -i "sine=frequency=440:duration=3" -c:a aac "$f" ;;
  esac
}
loud() { # loud FILE -> "I TP"
  "$REAL_FFMPEG" -hide_banner -nostdin -i "$1" -vn -af loudnorm=print_format=json -f null - 2>&1 </dev/null |
    awk -F'"' '/"input_i"/{i=$4} /"input_tp"/{tp=$4} END{print i, tp}'
}
fresh() { rm -rf "$OUT" "$MEDIA_DIR/DCIM/TikTok/"* "$MEDIA_DIR/Download/yt-dlp/"* ; : > "$LOGF"; }
run() { ( cd "$T/scripts" && "$@" ) >"$T/run.out" 2>&1; echo $?; }
vpk() { ffprobe -v error -select_streams v:0 -count_packets -show_entries stream=nb_read_packets -of csv=p=0 "$1" | tr -cd '0-9'; }
vcodec() { ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$1"; }

echo "== T1 quiet clip: stream-copy video, gain to -9 LUFS, original deleted"
fresh; S="$MEDIA_DIR/DCIM/TikTok/quiet_one.mp4"; mk "$S" libx264 quiet; spk=$(vpk "$S")
rc=$(run bash "$NORM" --file "$S")
O=$(ls "$OUT"/*.mp4 2>/dev/null | head -1)
chk "exit 0" "[[ $rc == 0 ]]"
chk "output exists in NormalizedVideo" "[[ -f '$O' ]]"
read -r li ltp <<<"$(loud "$O")"
chk "loudness ~ -9 LUFS (got $li)" "awk -v x=$li 'BEGIN{exit !(x>-9.6 && x<-8.4)}'"
chk "true peak <= -0.9 dBTP (got $ltp)" "awk -v x=$ltp 'BEGIN{exit !(x<=-0.9)}'"
chk "video stream-copied (packets equal $spk)" "[[ $(vpk "$O") == $spk ]] && [[ $(vcodec "$O") == h264 ]]"
chk "original deleted" "[[ ! -e '$S' ]]"
chk "no tmp files left" "[[ -z \$(ls '$OUT/.tmp' 2>/dev/null | grep -v '^.nomedia') ]]"
chk ".nomedia in tmp dir" "[[ -f '$OUT/.tmp/.nomedia' ]]"

echo "== T2 peaky clip: gain is CAPPED by true peak, constant gain only"
fresh; S="$MEDIA_DIR/DCIM/TikTok/peaky.mp4"; mk "$S" libx264 peaky
read -r si stp <<<"$(loud "$S")"
rc=$(run bash "$NORM" --file "$S"); O=$(ls "$OUT"/*.mp4 | head -1); read -r oi otp <<<"$(loud "$O")"
chk "exit 0" "[[ $rc == 0 ]]"
chk "log says PEAK CAP" "grep -q 'PEAK CAP' '$LOGF'"
chk "peak under ceiling (in $stp -> out $otp)" "awk -v x=$otp 'BEGIN{exit !(x<=-0.8)}'"
chk "target not forced (out $oi LUFS < -9, no limiter)" "awk -v x=$oi 'BEGIN{exit !(x<-9.5)}'"
chk "gain constant: loudness delta == peak delta" "awk -v a=$oi -v b=$si -v c=$otp -v d=$stp 'BEGIN{x=(a-b)-(c-d); if(x<0)x=-x; exit !(x<0.6)}'"

echo "== T3 non-copy codec (mpeg2) -> libx264 re-encode, frames kept"
fresh; S="$MEDIA_DIR/Download/yt-dlp/old codec (1).mkv"; mk "$S" mpeg2video quiet; spk=$(vpk "$S")
rc=$(run bash "$NORM" --file "$S"); O=$(ls "$OUT"/*.mp4 | head -1)
chk "exit 0" "[[ $rc == 0 ]]"
chk "re-encoded to h264" "[[ $(vcodec "$O") == h264 ]]"
chk "frame count kept ($spk)" "[[ $(vpk "$O") == $spk ]]"
chk "name sanitized" "[[ \$(basename '$O') == old_codec_1.mp4 ]]"

echo "== T4 no audio -> remux only"
fresh; S="$MEDIA_DIR/DCIM/TikTok/silent.mp4"; mk "$S" libx264 none
rc=$(run bash "$NORM" --file "$S"); O=$(ls "$OUT"/*.mp4 | head -1)
chk "exit 0 and output has no audio" "[[ $rc == 0 && -z \$(ffprobe -v error -select_streams a -show_entries stream=codec_type -of csv=p=0 '$O') ]]"

echo "== T5 audio-only file -> skipped, original kept (exit 2)"
fresh; S="$MEDIA_DIR/DCIM/TikTok/music.mp4"; mk "$S" libx264 only
rc=$(run bash "$NORM" --file "$S")
chk "exit 2, original kept, no output" "[[ $rc == 2 && -f '$S' && -z \$(ls '$OUT'/*.mp4 2>/dev/null) ]]"

echo "== T6 --keep-original keeps source"
fresh; S="$T/shared_local.mp4"; mk "$S" libx264 quiet
rc=$(run bash "$NORM" --file "$S" --keep-original)
chk "exit 0, output made, source kept" "[[ $rc == 0 && -f '$S' && -n \$(ls '$OUT'/*.mp4) ]]"

echo "== T7 stream-copy fails -> verified re-encode fallback"
fresh; S="$MEDIA_DIR/DCIM/TikTok/fb.mp4"; mk "$S" libx264 quiet
rc=$(PATH="$T/wrap:$PATH" FAKE_MODE=failcopy run bash "$NORM" --file "$S"); O=$(ls "$OUT"/*.mp4 | head -1)
chk "exit 0, output ok, original deleted" "[[ $rc == 0 && -f '$O' && ! -e '$S' ]]"
chk "log shows enc attempt succeeded" "grep -q 'SUCCESS.*video=enc' '$LOGF'"

echo "== T8 truncated stream-copy output is REJECTED by verification"
fresh; S="$MEDIA_DIR/DCIM/TikTok/trunc.mp4"; mk "$S" libx264 quiet
rc=$(PATH="$T/wrap:$PATH" FAKE_MODE=truncate run bash "$NORM" --file "$S"); O=$(ls "$OUT"/*.mp4 | head -1)
chk "rejection logged" "grep -q 'rejected by verification' '$LOGF'"
chk "final output complete (packets 100)" "[[ $rc == 0 && \$(vpk '$O') == 100 ]]"

echo "== T9 everything fails -> source preserved, exit 1, no leftovers"
fresh; S="$MEDIA_DIR/DCIM/TikTok/doomed.mp4"; mk "$S" libx264 quiet
rc=$(PATH="$T/wrap:$PATH" FAKE_MODE=failall run bash "$NORM" --file "$S")
chk "exit 1, source kept, no output, no tmp" "[[ $rc == 1 && -f '$S' && -z \$(ls '$OUT'/*.mp4 2>/dev/null) && -z \$(ls '$OUT/.tmp' | grep -v nomedia) ]]"

echo "== T10 scan mode (original behaviour): processes both folders"
fresh; mk "$MEDIA_DIR/DCIM/TikTok/a.mp4" libx264 quiet; mk "$MEDIA_DIR/Download/yt-dlp/b.mp4" libx264 quiet
touch -d '1 minute ago' "$MEDIA_DIR/DCIM/TikTok/a.mp4" "$MEDIA_DIR/Download/yt-dlp/b.mp4"
echo x > "$MEDIA_DIR/Download/yt-dlp/clip.f137.mp4"; touch -d '1 minute ago' "$MEDIA_DIR/Download/yt-dlp/clip.f137.mp4"
rc=$(run bash "$NORM")
chk "2 outputs, both originals gone" "[[ \$(ls '$OUT'/*.mp4 | wc -l) == 2 && ! -e '$MEDIA_DIR/DCIM/TikTok/a.mp4' ]]"
chk "yt-dlp fragment ignored" "[[ -f '$MEDIA_DIR/Download/yt-dlp/clip.f137.mp4' ]]"
chk "summary OK=2" "grep -q 'Videos OK=2, Failed=0' '$T/run.out'"

echo "== T11 ByteVC2 file -> fake yt-dlp returns H.264 -> normalized, bvc2 original removed"
fresh; GOOD="$T/good_src.mp4"; mk "$GOOD" libx264 quiet
cat > "$T/fakebin/yt-dlp" <<Y
#!/usr/bin/env bash
while [[ \$# -gt 0 ]]; do [[ "\$1" == "-o" ]] && o="\$2"; shift; done
cp "$GOOD" "\${o//%(id)s.%(ext)s/video.mp4}"
Y
chmod +x "$T/fakebin/yt-dlp"
B="$MEDIA_DIR/DCIM/TikTok/someuser_2026-10-16_7697297583915486497.mp4"; mk "$B" libx264 quiet
python3 - "$B" <<'PY'
import sys; p=sys.argv[1]; d=open(p,'rb').read(); assert b'avc1' in d; open(p,'wb').write(d.replace(b'avc1',b'bvc2'))
PY
touch -d '1 minute ago' "$B"
rc=$(PATH="$T/fakebin:$PATH" run bash "$NORM" --file "$B")
chk "exit 0" "[[ $rc == 0 ]]"
chk "bvc2 original removed" "[[ ! -e '$B' ]]"
chk "normalized output exists" "[[ \$(ls '$OUT'/*.mp4 | wc -l) == 1 ]]"
chk "no _h264 leftover" "[[ -z \$(ls '$MEDIA_DIR/DCIM/TikTok/' ) ]]"
echo "== T12 ByteVC2 with --keep-original / no yt-dlp -> kept untouched (exit 3)"
fresh; B="$MEDIA_DIR/DCIM/TikTok/someuser_2026-10-16_7697297583915486497.mp4"; mk "$B" libx264 quiet
python3 - "$B" <<'PY'
import sys; p=sys.argv[1]; d=open(p,'rb').read(); open(p,'wb').write(d.replace(b'avc1',b'bvc2'))
PY
rc=$(PATH="/usr/bin:/bin" run bash "$NORM" --file "$B")
chk "exit 3 and file kept" "[[ $rc == 3 && -f '$B' ]]"

echo "== T13 config guards"
rc=$(TARGET_LUFS=abc run bash "$NORM" --file /nonexistent); chk "bad TARGET_LUFS rejected (exit 64)" "[[ $rc == 64 ]]"
rc=$(run bash "$NORM" --file /nonexistent); chk "missing file -> exit 1" "[[ $rc == 1 ]]"
chk "default target is -9" "bash '$NORM' --help | grep -q 'Default: -9)'"

echo "== T14 source with damaged audio data -> still produces a verified output"
fresh; S="$MEDIA_DIR/DCIM/TikTok/damaged.mp4"; mk "$S" libx264 quiet
python3 - "$S" <<'PY2'
import sys,os; p=sys.argv[1]; b=bytearray(open(p,'rb').read()); n=len(b)
for i in range(int(n*0.55), int(n*0.55)+400): b[i]=0xFF
open(p,'wb').write(b)
PY2
rc=$(run bash "$NORM" --file "$S"); O=$(ls "$OUT"/*.mp4 2>/dev/null | head -1)
chk "exit 0 (or clean failure keeping source): rc=$rc" "[[ $rc == 0 && -f '$O' && ! -e '$S' ]] || [[ $rc == 1 && -f '$S' ]]"
chk "if saved: video packets complete" "[[ $rc != 0 ]] || [[ \$(vpk '$O') == 100 ]]"

echo "== T15 SIGTERM during render -> no tmp left, source kept"
if ! command -v pkill >/dev/null || ! command -v pgrep >/dev/null; then echo "  SKIP: pkill/pgrep missing (pkg install procps to run this test)"; else
fresh; S="$MEDIA_DIR/DCIM/TikTok/big.mp4"
"$REAL_FFMPEG" -v error -y -f lavfi -i "testsrc=size=1280x720:rate=30:duration=120" -f lavfi -i "sine=duration=120,volume=-25dB" -c:v mpeg2video -b:v 8M -c:a aac "$S"
( cd "$T/scripts" && bash "$NORM" --file "$S" >/dev/null 2>&1 ) & BP=$!
sleep 6; pkill -TERM -f "normalize.sh --file .*big.mp4"; wait $BP 2>/dev/null; sleep 1
chk "source kept" "[[ -f '$S' ]]"
chk "no output published" "[[ -z \$(ls '$OUT'/*.mp4 2>/dev/null) ]]"
chk "no tmp left" "[[ -z \$(ls '$OUT/.tmp' 2>/dev/null | grep -v '^.nomedia') ]]"
chk "no ffmpeg orphan" "! pgrep -f 'ffmpeg.*big.mp4' >/dev/null"
fi

echo; echo "RESULT: $pass passed, $failn failed"; exit $(( failn > 0 ))
