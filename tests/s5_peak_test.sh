#!/usr/bin/env bash
# S5 tests: percentage peak normalization (NORM_MODE=peak, the default). Temp dir only.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'pkill -f "$T/" 2>/dev/null; rm -rf "$T"' EXIT
S="$T/scripts"; mkdir -p "$S" "$T/wrap" "$T/media/DCIM/TikTok"
cp "$HERE/normalize.sh" "$HERE/config_lib.sh" "$S/"
export MEDIA_DIR="$T/media" HOME="$T/home"; mkdir -p "$HOME"
unset NORM_MODE PEAK_PERCENT PEAK_TOLERANCE PEAK_FALLBACK_TOLERANCE PIPELINE_CONFIG TARGET_LUFS
NORM="$S/normalize.sh"; LOGF="$S/media_processor_log.txt"; OUT="$MEDIA_DIR/Movies/NormalizedVideo"
REAL_FFMPEG="$(command -v ffmpeg)"
pass=0; failn=0
ok()  { pass=$((pass+1)); echo "  PASS: $1"; }
bad() { failn=$((failn+1)); echo "  FAIL: $1"; }
chk() { if eval "$2"; then ok "$1"; else bad "$1  [$2]"; fi; }
within() { awk -v v="$1" -v c="$2" -v tol="$3" 'BEGIN{d=v-c; if(d<0)d=-d; exit !(d<=tol)}'; }

cat > "$T/wrap/ffmpeg" <<W
#!/usr/bin/env bash
real="$REAL_FFMPEG"; a="\$*"
case "\${FAKE_MODE:-}" in
  failfinalvolume) [[ "\$a" == *"-map 0:v:0"* && "\$a" == *"volume="* ]] && exit 1 ;;
  failcopy)        [[ "\$a" == *"-c:v copy"* && "\$a" == *"-f mp4"* ]] && exit 1 ;;
  failastats)      [[ "\$a" == *"astats"* ]] && exit 1 ;;
esac
exec "\$real" "\$@"
W
chmod +x "$T/wrap/ffmpeg"

mk() { # mk FILE AUDIOSPEC [novideo]
  if [[ "${3:-}" == novideo ]]; then "$REAL_FFMPEG" -v error -y -f lavfi -i "$2" -c:a aac "$1"
  elif [[ "$2" == none ]]; then "$REAL_FFMPEG" -v error -y -f lavfi -i "testsrc=size=320x240:rate=25:duration=4" -c:v libx264 -pix_fmt yuv420p -g 25 -an "$1"
  else "$REAL_FFMPEG" -v error -y -f lavfi -i "testsrc=size=320x240:rate=25:duration=${4:-4}" -f lavfi -i "$2" -c:v libx264 -pix_fmt yuv420p -g 25 -c:a aac -shortest "$1"; fi
}
astat() { "$REAL_FFMPEG" -hide_banner -nostdin -i "$1" -vn -af astats=metadata=0:reset=0 -f null - 2>&1 </dev/null | awk -v k="$2" '/Overall/{o=1} o&&index($0,k){print $NF; exit}'; }
vpk() { ffprobe -v error -select_streams v:0 -count_packets -show_entries stream=nb_read_packets -of csv=p=0 "$1" | tr -cd '0-9'; }
fresh() { rm -rf "$MEDIA_DIR/Movies" "$T/work"; mkdir -p "$T/work"; : > "$LOGF"; }
run() { ( cd "$S" && "$@" ) > "$T/run.out" 2>&1; echo $?; }
outfile() { ls "$OUT"/*.mp4 2>/dev/null | head -1; }
within_fb() { awk -v p="$1" -v t="$2" 'BEGIN{e=t-p; exit !(e>=-0.001 && e<=0.30)}'; }   # documented fallback window: NEVER above target, at most 0.30 below
ceil_ok() { awk -v p="$1" -v t="$2" 'BEGIN{exit !(p<=t+0.001)}'; }                        # the target is a CEILING
SPEC_LOUD="sine=frequency=440:duration=4,volume=-0.5dB"
SPEC_PEAKY="aevalsrc='if(lt(mod(t,1),0.004),0.95*sin(2*PI*1000*t),0.004*sin(2*PI*200*t))':s=44100:d=4"
SPEC_VAR="aevalsrc='(0.05+0.45*abs(sin(2*PI*0.5*t)))*sin(2*PI*300*t)|(0.05+0.45*abs(sin(2*PI*0.5*t)))*sin(2*PI*500*t)':s=44100:d=4"
SPEC_NOISE="anoisesrc=d=4:c=pink:r=44100:a=0.3:seed=7"

echo "== P1 percentage -> dB (Target = -9 + 8.9 * p/100)"
for pair in "0:-9.000" "25:-6.775" "50:-4.550" "75:-2.325" "100:-0.100" "33.3:-6.036" "0.5:-8.956"; do
  p=${pair%%:*}; e=${pair##*:}
  chk "$p% -> $e dB" "PEAK_PERCENT=$p bash '$NORM' --help | grep -q 'Current setting: $p% = $e dB, mode peak'"
done
chk "default is peak mode at 100% = -0.100 dB" "bash '$NORM' --help | grep -q 'Current setting: 100% = -0.100 dB, mode peak'"

echo "== P2 invalid settings are refused (exit 64), never guessed"
for kv in PEAK_PERCENT=-1 PEAK_PERCENT=101 PEAK_PERCENT=abc "PEAK_PERCENT=50;x" PEAK_PERCENT=1e2 NORM_MODE=both PEAK_TOLERANCE=0 PEAK_TOLERANCE=5 PEAK_FALLBACK_TOLERANCE=2; do
  env "$kv" bash "$NORM" --help >/dev/null 2>&1; chk "$kv -> 64" "[[ $? == 64 ]]"
done

echo "== P3 accuracy: the OUTPUT's real peak lands on the target (measured independently)"
for spec in LOUD PEAKY VAR; do for pct in 0 50 100; do
  fresh; eval "sp=\$SPEC_$spec"; mk "$T/work/c.mp4" "$sp"; t=$(awk -v p=$pct 'BEGIN{printf "%.3f",-9+8.9*p/100}'); spk=$(vpk "$T/work/c.mp4")
  rc=$(PEAK_PERCENT=$pct run bash "$NORM" --file "$T/work/c.mp4" --keep-original); o=$(outfile); op=$(astat "$o" "Peak level dB:")
  appr=$(grep -c APPROXIMATE "$LOGF")
  chk "$spec @ $pct%: rc 0, peak $op vs target $t (never above it; 0..0.05 below, OR flagged APPROXIMATE up to 0.30 below), video stream-copied" "[[ $rc == 0 ]] && ceil_ok '$op' '$t' && { within '$op' '$t' 0.06 || { [[ $appr -ge 1 ]] && within_fb '$op' '$t'; }; } && [[ \$(vpk '$o') == $spk ]]"
  [[ $appr -ge 1 ]] && echo "    (info: $spec @ $pct% used the APPROXIMATE fallback on this machine: peak $op, target $t)"
done; done

echo "== P3b the target is a CEILING: across the whole 0-100% range the output peak is never above it"
ceil_bad=0; ceil_n=0; strict_n=0; refused_n=0
for spec in PEAKY VAR NOISE; do for pct in 0 10 25 50 75 90 100; do
  fresh; eval "sp=\$SPEC_$spec"; mk "$T/work/c.mp4" "$sp"; t=$(awk -v p=$pct 'BEGIN{printf "%.3f",-9+8.9*p/100}')
  rc=$(PEAK_PERCENT=$pct run bash "$NORM" --file "$T/work/c.mp4" --keep-original); o=$(outfile)
  ceil_n=$((ceil_n+1))
  if [[ $rc == 0 ]]; then
    op=$(astat "$o" "Peak level dB:")
    if ! ceil_ok "$op" "$t" || ! within_fb "$op" "$t"; then ceil_bad=$((ceil_bad+1)); echo "    BAD: $spec @ $pct%: peak=$op target=$t"; fi
    within "$op" "$t" 0.06 && strict_n=$((strict_n+1))
  else   # contract: if AAC cannot reach the window the file is REFUSED: nothing saved, nothing un-normalized, source kept
    refused_n=$((refused_n+1))
    if [[ -n "$o" ]] || ! grep -q "not reachable" "$LOGF" || [[ ! -f "$T/work/c.mp4" ]]; then ceil_bad=$((ceil_bad+1)); echo "    BAD: $spec @ $pct%: rc=$rc but output='$o' or no 'not reachable' log"; else echo "    (info: $spec @ $pct%: refused as unreachable, original kept - by design)"; fi
  fi
done; done
chk "$ceil_n runs: none above the target, none more than 0.30 dB below, any refusal keeps the original ($strict_n within 0.05 dB, $refused_n refused)" "[[ $ceil_bad == 0 ]]"

echo "== P4 constant gain only: dynamics preserved (RMS shifts exactly like the peak)"
for spec in VAR PEAKY; do
  fresh; eval "sp=\$SPEC_$spec"; mk "$T/work/c.mp4" "$sp"
  ip=$(astat "$T/work/c.mp4" "Peak level dB:"); ir=$(astat "$T/work/c.mp4" "RMS level dB:")
  PEAK_PERCENT=50 run bash "$NORM" --file "$T/work/c.mp4" --keep-original >/dev/null; o=$(outfile)
  op=$(astat "$o" "Peak level dB:"); or=$(astat "$o" "RMS level dB:")
  chk "$spec: (RMS shift) - (peak shift) within 0.2 dB: $(awk -v a=$or -v b=$ir -v c=$op -v d=$ip 'BEGIN{printf "%+.3f",(a-b)-(c-d)}')" "within \"\$(awk -v a=$or -v b=$ir -v c=$op -v d=$ip 'BEGIN{print (a-b)-(c-d)}')\" 0 0.2"
done

echo "== P5 hard case: full-scale noise at 100% (AAC may not be able to hit it within the strict window)"
# Which noise is "hard" depends on the ffmpeg build, so look for a seed where strict-only is refused but the default succeeds.
found=""
for seed in 2 3 6 8 10 11 1 4 5 7 9 12 13 14 15 16; do
  fresh; mk "$T/work/n.mp4" "anoisesrc=d=4:c=pink:r=44100:a=0.3:seed=$seed"
  rcs=$(PEAK_PERCENT=100 PEAK_FALLBACK_TOLERANCE=0 run bash "$NORM" --file "$T/work/n.mp4" --keep-original)
  if [[ $rcs == 1 ]]; then
    rm -rf "$MEDIA_DIR/Movies"; : > "$LOGF"
    rcd=$(PEAK_PERCENT=100 run bash "$NORM" --file "$T/work/n.mp4" --keep-original)
    if [[ $rcd == 0 ]]; then found=$seed; break; fi
  fi
done
if [[ -z "$found" ]]; then echo "  SKIP: no 'hard' noise found on this ffmpeg (every try hit the strict window or was refused)"
else
  o=$(outfile); op=$(astat "$o" "Peak level dB:")
  chk "seed $found default: output made, flagged APPROXIMATE, peak $op never above 0 dBFS and within -0.4..0.0" "grep -q APPROXIMATE '$LOGF' && awk -v p=$op 'BEGIN{exit !(p<=0 && p>=-0.4)}'"
  fresh; mk "$T/work/n.mp4" "anoisesrc=d=4:c=pink:r=44100:a=0.3:seed=$found"
  rc=$(PEAK_PERCENT=100 PEAK_FALLBACK_TOLERANCE=0 run bash "$NORM" --file "$T/work/n.mp4")
  chk "seed $found PEAK_FALLBACK_TOLERANCE=0 (strict only): refused, original KEPT, nothing saved" "[[ $rc == 1 && -f '$T/work/n.mp4' && -z \$(outfile) ]]"
fi

echo "== P6 MANDATORY: the gain is always applied, nothing can bypass it"
fresh; mk "$T/work/a.mp4" "$SPEC_VAR"; PEAK_PERCENT=50 run bash "$NORM" --file "$T/work/a.mp4" --keep-original >/dev/null; cp "$(outfile)" "$T/work/again.mp4"; rm -rf "$MEDIA_DIR/Movies"; : > "$LOGF"
rc=$(PEAK_PERCENT=50 run bash "$NORM" --file "$T/work/again.mp4" --keep-original)
chk "file already at the target (gain ~0): the filter+re-encode still runs (no audio copy)" "[[ $rc == 0 ]] && grep -q 'ATTEMPT video=copy audio=gain' '$LOGF' && ! grep -q 'audio=acopy' '$LOGF' && grep -q 'Applying Constant Linear Gain' '$LOGF'"
fresh; mk "$T/work/b.mp4" "$SPEC_VAR"
rc=$(PATH="$T/wrap:$PATH" FAKE_MODE=failfinalvolume PEAK_PERCENT=50 run bash "$NORM" --file "$T/work/b.mp4")
chk "filter step failing: file FAILS, original kept, no output (never saved un-normalized)" "[[ $rc == 1 && -f '$T/work/b.mp4' && -z \$(outfile) ]]"
chk "...and no 'copy audio' / 'strip audio' fallback was attempted" "! grep -qE 'audio=(acopy|none)' '$LOGF'"
fresh; mk "$T/work/c.mp4" "$SPEC_VAR"
rc=$(PATH="$T/wrap:$PATH" FAKE_MODE=failcopy PEAK_PERCENT=50 run bash "$NORM" --file "$T/work/c.mp4"); o=$(outfile)
chk "video stream-copy fails: falls back to video re-encode, audio STILL normalized (peak $(astat "$o" "Peak level dB:"))" "[[ $rc == 0 ]] && grep -q 'SUCCESS.*video=enc audio=gain' '$LOGF' && within \"\$(astat '$o' 'Peak level dB:')\" -4.55 0.06"
fresh; mk "$T/work/d.mp4" "$SPEC_VAR"
rc=$(PATH="$T/wrap:$PATH" FAKE_MODE=failastats PEAK_PERCENT=50 run bash "$NORM" --file "$T/work/d.mp4")
chk "audio cannot be measured: FAILS with a clear message, original kept" "[[ $rc == 1 && -f '$T/work/d.mp4' && -z \$(outfile) ]] && grep -q 'could not be measured' '$T/run.out'"
fresh; mk "$T/work/s.mp4" "anullsrc=r=44100:cl=stereo,atrim=duration=3"
rc=$(PEAK_PERCENT=50 run bash "$NORM" --file "$T/work/s.mp4" --keep-original)
chk "digital silence: processed, filter still applied at 0 dB, no crash" "[[ $rc == 0 && -n \$(outfile) ]] && grep -q 'digital silence' '$LOGF'"
fresh; mk "$T/work/v.mp4" none
rc=$(PEAK_PERCENT=50 run bash "$NORM" --file "$T/work/v.mp4" --keep-original)
chk "no audio track: remuxed (nothing to normalize), reported" "[[ $rc == 0 && -n \$(outfile) ]] && grep -q 'nothing to normalize' '$T/run.out'"
fresh; mk "$T/work/m.mp4" "sine=duration=3" novideo
rc=$(PEAK_PERCENT=50 run bash "$NORM" --file "$T/work/m.mp4" --keep-original)
chk "audio-only file: skipped (exit 2), not a video" "[[ $rc == 2 && -z \$(outfile) ]]"

echo "== P7 settings: config file, environment wins, hostile lines ignored"
fresh; mk "$T/work/e.mp4" "$SPEC_VAR"; mkdir -p "$S/data"
printf 'PEAK_PERCENT=0\nFOO=bar\nPEAK_PERCENT=50; touch %s/pwned\n' "$T" > "$S/data/config.conf"
rc=$(run bash "$NORM" --file "$T/work/e.mp4" --keep-original); o=$(outfile)
chk "config PEAK_PERCENT=0 -> -9.000 dB, hostile line ignored, nothing executed" "[[ $rc == 0 ]] && within \"\$(astat '$o' 'Peak level dB:')\" -9 0.06 && [[ ! -e '$T/pwned' ]]"
fresh; mk "$T/work/e.mp4" "$SPEC_VAR"; printf 'PEAK_PERCENT=0\n' > "$S/data/config.conf"
rc=$(PEAK_PERCENT=50 run bash "$NORM" --file "$T/work/e.mp4" --keep-original); o=$(outfile)
chk "environment PEAK_PERCENT=50 beats config 0 -> -4.55 dB" "[[ $rc == 0 ]] && within \"\$(astat '$o' 'Peak level dB:')\" -4.55 0.06"
rm -f "$S/data/config.conf"

echo "== P8 LUFS mode still available (NORM_MODE=lufs)"
fresh; mk "$T/work/l.mp4" "sine=frequency=440:duration=4,volume=-28dB"
rc=$(NORM_MODE=lufs run bash "$NORM" --file "$T/work/l.mp4" --keep-original)
chk "lufs mode works as before" "[[ $rc == 0 && -n \$(outfile) ]] && grep -q 'LUFS: .* -> Applying' '$LOGF'"

echo "== P9 scan mode (tiktok folder): every video normalized"
fresh; for n in a b c; do mk "$MEDIA_DIR/DCIM/TikTok/v_$n.mp4" "$SPEC_VAR"; done; touch -d '1 minute ago' "$MEDIA_DIR/DCIM/TikTok/"*
rc=$(PEAK_PERCENT=75 run bash "$NORM")
bad_n=0; for f in "$OUT"/*.mp4; do within "$(astat "$f" 'Peak level dB:')" -2.325 0.06 || bad_n=$((bad_n+1)); done
chk "3 files, each peak at -2.325 dB (75%), originals consumed" "[[ \$(ls '$OUT'/*.mp4 | wc -l) == 3 && $bad_n == 0 && -z \$(ls '$MEDIA_DIR/DCIM/TikTok') ]]"

echo "== P10 killed during calibration: nothing left behind"
fresh; mk "$T/work/big.mp4" "anoisesrc=d=240:c=pink:r=44100:a=0.3" x 240
( cd "$S" && PEAK_PERCENT=100 bash "$NORM" --file "$T/work/big.mp4" >/dev/null 2>&1 ) & BP=$!
sleep 6; pkill -TERM -f "normalize.sh --file .*big.mp4"; wait $BP 2>/dev/null; sleep 1
chk "source kept, no output, no .cal/.tmp files, no ffmpeg orphan" "[[ -f '$T/work/big.mp4' && -z \$(outfile) && -z \$(ls -A '$OUT/.tmp' 2>/dev/null | grep -v '^.nomedia$') ]] && ! pgrep -f 'ffmpeg.*big.mp4' >/dev/null"

echo; echo "RESULT: $pass passed, $failn failed"; exit $(( failn > 0 ))
