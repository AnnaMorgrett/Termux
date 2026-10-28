#!/usr/bin/env python3
"""S2 tests: web UI server (webui.py), config reaching the scripts, security checks.
Temp dirs only. Needs ffmpeg/ffprobe/bash/python3."""
import http.client, json, os, shutil, socket, subprocess, sys, tempfile, time, stat

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
T = tempfile.mkdtemp()
S = os.path.join(T, "scripts"); os.makedirs(S)
for f in "normalize.sh worker.sh qctl.py download.sh scan_lib.sh q.sh shortcuts.sh config_lib.sh webui.py webui.html".split():
    shutil.copy(os.path.join(HERE, f), S)
MEDIA = os.path.join(T, "media"); FB = os.path.join(T, "fakebin"); os.makedirs(FB)
OUT = os.path.join(MEDIA, "Movies", "NormalizedVideo")
def free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p
PORT = free_port()
ENV = dict(os.environ, NORM_MODE="lufs", MEDIA_DIR=MEDIA, WEBUI_PORT=str(PORT), PATH=FB + ":" + os.environ["PATH"], TMPDIR=T)
for k in ("QUEUE_DIR", "PIPELINE_CONFIG", "TARGET_LUFS"):
    ENV.pop(k, None)
passed = failed = 0
def chk(name, cond, extra=""):
    global passed, failed
    if cond: passed += 1; print("  PASS:", name)
    else: failed += 1; print("  FAIL:", name, extra)
def sh(cmd, env=None, timeout=120):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True, env=env or ENV, timeout=timeout, cwd=S)

subprocess.run(["ffmpeg","-v","error","-y","-f","lavfi","-i","testsrc=size=320x240:rate=25:duration=3","-f","lavfi","-i",
                "sine=frequency=440:duration=3,volume=-28dB","-c:v","libx264","-pix_fmt","yuv420p","-c:a","aac","-shortest",os.path.join(T,"good.mp4")],check=True)
open(os.path.join(FB,"yt-dlp"),"w").write(f'''#!/usr/bin/env bash
[[ "${{1:-}}" == "-U" ]] && exit 0
dir=""; res=""; url=""
while [[ $# -gt 0 ]]; do case "$1" in -P) dir="$2"; shift 2;; --print-to-file) res="$3"; shift 3;; -o|-S) shift 2;; -*) shift;; *) url="$1"; shift;; esac; done
[[ "$url" == *bad* ]] && exit 1
id=$(basename "$url" | tr -cd 'A-Za-z0-9'); mkdir -p "$dir"
f="$dir/T $id [$id].mp4"; cp "{T}/good.mp4" "$f"; [[ -n "$res" ]] && echo "$f" >> "$res"
''')
open(os.path.join(FB,"termux-media-scan"),"w").write("#!/usr/bin/env bash\nexit 0\n")
for f in os.listdir(FB): os.chmod(os.path.join(FB,f), 0o755)

def req(method, path, body=None, headers=None, port=None, raw=None):
    c = http.client.HTTPConnection("127.0.0.1", port or PORT, timeout=20)
    h = {"Host": "127.0.0.1:%d" % (port or PORT)}
    if method == "POST":
        h.update({"Content-Type": "application/json", "X-Requested-With": "q-ui"})
    h.update(headers or {})
    h = {k: v for k, v in h.items() if v is not None}
    data = raw if raw is not None else (json.dumps(body) if body is not None else None)
    c.request(method, path, body=data, headers=h)
    r = c.getresponse(); b = r.read(); c.close()
    try: j = json.loads(b)
    except ValueError: j = None
    return r.status, j, b, dict(r.getheaders())
def waitfor(fn, t=40):
    end = time.time() + t
    while time.time() < end:
        if fn(): return True
        time.sleep(0.4)
    return False
def loud(p):
    r = subprocess.run(["ffmpeg","-hide_banner","-nostdin","-i",p,"-vn","-af","loudnorm=print_format=json","-f","null","-"],capture_output=True,text=True)
    import re
    return float(re.search(r'"input_i"\s*:\s*"([-\d.]+)"', r.stderr).group(1))
def outs(): return sorted(f for f in os.listdir(OUT) if f.endswith(".mp4")) if os.path.isdir(OUT) else []
CFG = os.path.join(S, "data", "config.conf")

try:
    print("== U1 start/stop via q ui")
    r = sh("bash q.sh ui start")
    chk("q ui start prints URL", "Web UI started: http://127.0.0.1:%d" % PORT in r.stdout, r.stdout + r.stderr)
    r2 = sh("bash q.sh ui start"); chk("second start says already running", "already running" in r2.stdout)
    st, j, b, h = req("GET", "/")
    chk("page served (html, no-store, CSP)", st == 200 and b.startswith(b"<!doctype html>") and "no-store" in h.get("Cache-Control","") and "Content-Security-Policy" in h)
    chk("page is small and has no external URLs", len(b) < 40000 and b"http://" not in b and b"https://" not in b)
    chk("q ui status", "running" in sh("bash q.sh ui status").stdout)

    print("== U2 security")
    chk("wrong Host header rejected (DNS rebinding)", req("GET", "/api/status", headers={"Host": "evil.com"})[0] == 403)
    chk("wrong Host with right port rejected", req("GET", "/api/status", headers={"Host": "evil.com:%d" % PORT})[0] == 403)
    chk("foreign Origin rejected on GET", req("GET", "/api/status", headers={"Origin": "http://evil.com"})[0] == 403)
    chk("POST without X-Requested-With rejected", req("POST", "/api/clear", {"statuses": ["done"]}, headers={"X-Requested-With": None})[0] == 403)
    chk("POST with foreign Origin rejected", req("POST", "/api/clear", {"statuses": ["done"]}, headers={"Origin": "http://evil.com"})[0] == 403)
    chk("POST non-JSON rejected (400)", req("POST", "/api/add", raw="items=x", headers={"Content-Type": "text/plain"})[0] == 400)
    chk("oversized body rejected", req("POST", "/api/add", raw="{" + " " * 70000 + "}")[0] == 400)
    chk("unknown route 404", req("GET", "/etc/passwd")[0] == 404 and req("GET", "/../../etc/passwd")[0] == 404)
    chk("bad status filter 400", req("GET", "/api/jobs?status=evil")[0] == 400)
    def listen_addr(port):
        try:
            for line in open("/proc/net/tcp").read().splitlines()[1:]:
                f = line.split()
                if f[3] == "0A" and int(f[1].split(":")[1], 16) == port:
                    return f[1].split(":")[0]
        except OSError:
            pass
        return None
    la = listen_addr(PORT)
    if la is None: print("  SKIP: cannot read /proc/net/tcp here")
    else: chk("server bound to loopback only (127.0.0.1)", la == "0100007F", la)

    print("== U3 add via API -> worker -> outputs; status, jobs, logs")
    shutil.copy(os.path.join(T,"good.mp4"), os.path.join(T,"local one.mp4"))
    items = "https://s.com/one\nhttps://s.com/two  https://s.com/three\nhttps://s.com/one\njust some words\n%s\n" % os.path.join(T, "local one.mp4")
    st, j, *_ = req("POST", "/api/add", {"items": items})
    res = j["results"]
    chk("4 queued, 1 duplicate, 1 rejected", st == 200 and sum(r["ok"] for r in res) == 4 and sum("duplicate" in r["msg"] for r in res) == 1 and sum("not a link" in r["msg"] for r in res) == 1, json.dumps(res))
    chk("all jobs finish (worker auto-started)", waitfor(lambda: req("GET", "/api/status")[1]["stats"]["done"] == 4, 90))
    chk("4 outputs, local file kept", len(outs()) == 4 and os.path.exists(os.path.join(T, "local one.mp4")))
    st, j, *_ = req("GET", "/api/jobs?status=done")
    chk("jobs API: newest first, outputs listed, no internal key", [x["id"] for x in j["jobs"]] == [4,3,2,1] and all(x.get("output") for x in j["jobs"]) and not any("key" in x for x in j["jobs"]))
    chk("worker idle after finishing", waitfor(lambda: not req("GET", "/api/status")[1]["worker"]["running"], 15))
    # the worker frees its lock (UI shows idle) a moment BEFORE it writes "Worker finished": wait for that line
    waitfor(lambda: any("Worker finished" in l for l in req("GET", "/api/logs?n=300&events=1")[1]["lines"]), 20)
    st, j, *_ = req("GET", "/api/logs?n=300&events=1")
    ev = j["lines"]
    chk("logs (events only): worker lines present, no ffmpeg noise", any("Job 1 DONE" in l for l in ev) and any("Worker finished" in l for l in ev) and all(l.startswith("[20") for l in ev), "%d lines; last: %s" % (len(ev), ev[-3:]))
    st, j, *_ = req("GET", "/api/logs?n=1000")
    raw = j["lines"]
    chk("logs (raw) also include ffmpeg output", len(raw) > len(ev) and any(not l.startswith("[20") for l in raw), "raw=%d events=%d" % (len(raw), len(ev)))
    with open(os.path.join(S, "media_processor_log.txt"), "a") as lf:      # simulate a noisier ffmpeg (as on a phone)
        lf.write("".join("  Stream #0:%d -> #0:%d (copy) noise line %d\n" % (i % 3, i % 3, i) for i in range(1500)))
    st, j, *_ = req("GET", "/api/logs?n=300&events=1")
    chk("events view still shows worker lines after 1500 noise lines", any("Job 1 DONE" in l for l in j["lines"]))
    st, j, *_ = req("GET", "/api/logs?n=300")
    chk("(raw view is flooded: worker lines pushed out, as seen on the phone)", not any("Job 1 DONE" in l for l in j["lines"]))

    print("== U4 settings: validation, reaching the scripts, safety")
    st, j, *_ = req("GET", "/api/config")
    chk("defaults reported", j["values"]["TARGET_LUFS"] == "-9" and j["defaults"]["AUDIO_BITRATE"] == "192k" and j["custom"] == [])
    bad = [{"TARGET_LUFS": "abc"}, {"TARGET_LUFS": "-9; touch /tmp/pwn_%d" % PORT}, {"TARGET_LUFS": "5"}, {"TARGET_LUFS": "-99"}, {"TRUE_PEAK_CEILING": "3"},
           {"VERIFY_DECODE": "2"}, {"AUDIO_BITRATE": "9999k"}, {"AUDIO_BITRATE": "192k\nTARGET_LUFS=1"}, {"FFMPEG_LOGLEVEL": "debug;x"}, {"NOPE": "1"},
           {"PEAK_PERCENT": "101"}, {"PEAK_PERCENT": "-1"}, {"PEAK_PERCENT": "-0"}, {"PEAK_PERCENT": "abc"}, {"PEAK_PERCENT": "50;x"}, {"PEAK_PERCENT": "1e2"}, {"NORM_MODE": "both"}]
    codes = [req("POST", "/api/config", {"values": v})[0] for v in bad]
    chk("all %d invalid values rejected (400)" % len(bad), codes == [400] * len(bad), str(codes))
    chk("nothing written, nothing executed", not os.path.exists(CFG) and not os.path.exists("/tmp/pwn_%d" % PORT))
    st, j, *_ = req("POST", "/api/config", {"values": {"NORM_MODE": "peak", "PEAK_PERCENT": "50"}})
    chk("peak settings accepted and stored", st == 200 and "NORM_MODE" not in open(CFG).read() and "PEAK_PERCENT=50" in open(CFG).read(), open(CFG).read())
    req("POST", "/api/config", {"reset": True})
    st, j, *_ = req("POST", "/api/config", {"values": {"TARGET_LUFS": "-14", "AUDIO_BITRATE": "128k", "VERIFY_DECODE": "1"}})
    chk("valid save ok; defaults are not stored", st == 200 and j["custom"] == ["AUDIO_BITRATE", "TARGET_LUFS"])
    chk("config file is plain KEY=VALUE", open(CFG).read().count("=") == 2 and "TARGET_LUFS=-14" in open(CFG).read())
    before = set(outs())
    req("POST", "/api/add", {"items": "https://s.com/cfgtest"})
    waitfor(lambda: len(outs()) == len(before) + 1, 60)
    new = [f for f in outs() if f not in before]
    chk("new setting used by the next job (-14 LUFS)", bool(new) and abs(loud(os.path.join(OUT, new[0])) - (-14)) < 0.7, str(new))
    # env var beats the file; hostile file content is ignored
    clip = os.path.join(T, "env.mp4"); shutil.copy(os.path.join(T, "good.mp4"), clip)
    open(CFG, "w").write("TARGET_LUFS=-14; touch /tmp/pwn2_%d\nFOO=bar\nTARGET_LUFS=-12\n" % PORT)
    e = dict(ENV, QUEUE_DIR=os.path.join(S, "data", "queue"))
    sh("bash normalize.sh --file '%s' --keep-original" % clip, env=e)
    nl = [f for f in outs() if f not in before and f not in new]
    chk("hostile config line ignored, valid line used (-12), no code run", bool(nl) and abs(loud(os.path.join(OUT, nl[0])) - (-12)) < 0.7 and not os.path.exists("/tmp/pwn2_%d" % PORT), str(nl))
    open(CFG, "w").write("TARGET_LUFS=-14\n")
    sh("bash normalize.sh --file '%s' --keep-original" % clip, env=dict(e, TARGET_LUFS="-20"))
    nl2 = [f for f in outs() if f not in before and f not in new and f not in nl]
    chk("real environment variable beats the config file (-20)", bool(nl2) and abs(loud(os.path.join(OUT, nl2[0])) - (-20)) < 0.7, str(nl2))
    st, j, *_ = req("POST", "/api/config", {"values": {"TARGET_LUFS": "-9"}})
    chk("saving a default value removes it from the file", j["custom"] == [] and "TARGET_LUFS" not in open(CFG).read())
    req("POST", "/api/config", {"values": {"FFMPEG_LOGLEVEL": "warning"}}); st, j, *_ = req("POST", "/api/config", {"reset": True})
    chk("reset clears all custom settings", j["custom"] == [] and "FFMPEG" not in open(CFG).read())

    print("== U5 retry / remove / clear / worker control")
    req("POST", "/api/add", {"items": "https://s.com/bad1"})
    chk("failing job recorded", waitfor(lambda: req("GET", "/api/status")[1]["stats"]["failed"] == 1, 40))
    fid = req("GET", "/api/jobs?status=failed")[1]["jobs"][0]["id"]
    chk("failure reason shown", "download failed" in req("GET", "/api/jobs?status=failed")[1]["jobs"][0]["error"])
    req("POST", "/api/retry", {"id": fid})
    chk("retry runs again and fails again", waitfor(lambda: (lambda s: s["stats"]["failed"] == 1 and s["stats"]["pending"] == 0 and not s["worker"]["running"])(req("GET", "/api/status")[1]), 40))
    chk("retry with bad id -> 400", req("POST", "/api/retry", {"id": "x"})[0] == 400)
    chk("remove failed job", req("POST", "/api/remove", {"id": fid})[1]["ok"] and req("GET", "/api/status")[1]["stats"]["failed"] == 0)
    chk("clear done", req("POST", "/api/clear", {"statuses": ["done"]})[1]["ok"] and req("GET", "/api/status")[1]["stats"]["done"] == 0)
    chk("clear with nothing chosen -> 400", req("POST", "/api/clear", {"statuses": ["pending"]})[0] == 400)
    chk("worker start/stop endpoints answer", req("POST", "/api/worker", {"action": "start"})[0] == 200 and req("POST", "/api/worker", {"action": "stop"})[0] == 200 and req("POST", "/api/worker", {"action": "boom"})[0] == 400)

    print("== U6 stop")
    r = sh("bash q.sh ui stop"); time.sleep(0.5)
    chk("q ui stop stops the server", "stopped" in r.stdout and subprocess.run("(echo > /dev/tcp/127.0.0.1/%d) 2>/dev/null" % PORT, shell=True, executable="/bin/bash").returncode != 0)

    print("== U7 LAN mode requires a token")
    P2 = free_port()
    env2 = dict(ENV, WEBUI_HOST="127.0.0.1", WEBUI_PORT=str(P2))
    # emulate non-loopback by binding 0.0.0.0
    env2["WEBUI_HOST"] = "0.0.0.0"
    p = subprocess.Popen([sys.executable, os.path.join(S, "webui.py")], env=env2, cwd=S, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    waitfor(lambda: subprocess.run("(echo > /dev/tcp/127.0.0.1/%d) 2>/dev/null" % P2, shell=True, executable="/bin/bash").returncode == 0, 10)
    tok = open(os.path.join(S, "data", "webui.token")).read().strip()
    chk("token file private (0600)", stat.S_IMODE(os.stat(os.path.join(S, "data", "webui.token")).st_mode) == 0o600)
    chk("no token -> 401", req("GET", "/api/status", port=P2)[0] == 401)
    chk("wrong token -> 401", req("GET", "/?t=nope", port=P2)[0] == 401)
    st, _, _, h = req("GET", "/?t=" + tok, port=P2)
    chk("right token -> 200 and cookie", st == 200 and "qt=" in h.get("Set-Cookie", "") and "HttpOnly" in h.get("Set-Cookie", ""))
    chk("cookie works afterwards", req("GET", "/api/status", headers={"Cookie": "qt=" + tok}, port=P2)[0] == 200)
    chk("POST still needs the header even with token", req("POST", "/api/clear", {"statuses": ["done"]}, headers={"Cookie": "qt=" + tok, "X-Requested-With": None}, port=P2)[0] == 403)
    p.terminate(); p.wait(5)
finally:
    sh("bash q.sh ui stop"); subprocess.run("pkill -f '%s/' 2>/dev/null" % T, shell=True)
    shutil.rmtree(T, ignore_errors=True)
print("\nRESULT: %d passed, %d failed" % (passed, failed))
sys.exit(1 if failed else 0)
