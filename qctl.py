#!/usr/bin/env python3
"""qctl - persistent FIFO job queue (one JSON file per job). Python stdlib only.

Layout:  $QUEUE_DIR/<seq>.<status>.json   status = pending | running | done | failed
Safety:  all changes happen under an exclusive mkdir lock (works on shared storage); files are written to a temp
         name and renamed (atomic), so a kill/power loss never leaves half a job.
Exit codes: 0 ok | 1 nothing to do / not found | 2 bad input | 3 duplicate | 4 queue busy
"""
import argparse, json, os, random, re, shutil, sys, time
from urllib.parse import urlsplit, urlunsplit, parse_qsl, urlencode

HERE = os.path.dirname(os.path.abspath(__file__))
QDIR = os.environ.get("QUEUE_DIR") or os.path.join(HERE, "data", "queue")
MAX_ATTEMPTS = int(os.environ.get("QUEUE_MAX_ATTEMPTS", "3"))
KEEP_DONE_DAYS = int(os.environ.get("QUEUE_KEEP_DONE_DAYS", "14"))
STATUSES = ("pending", "running", "done", "failed")
TRACKING = {"si", "feature", "igshid", "is_from_webapp", "sender_device", "web_id", "fbclid",
            "gclid", "share_app_id", "share_link_id", "_r", "_t", "checksum", "pp"}
NAME_RE = re.compile(r"^(\d{8})\.(pending|running|done|failed)\.json$")


def now():
    return time.time()


class Locked:
    """Exclusive lock for queue changes, made with an atomic mkdir. Works on EVERY filesystem,
    including Android shared storage (/storage/emulated/0), which has no flock (errno 38).
    A lock whose owner process is gone (kill -9, crash, reboot) is taken over automatically."""
    TIMEOUT = float(os.environ.get("QUEUE_LOCK_TIMEOUT") or os.environ.get("QCTL_LOCK_TIMEOUT") or "30")

    def __enter__(self):
        os.makedirs(QDIR, exist_ok=True)
        d = os.path.join(QDIR, ".lock.d")
        end = time.time() + self.TIMEOUT
        while True:
            try:
                os.mkdir(d)
                with open(os.path.join(d, "pid"), "w") as f:
                    f.write(str(os.getpid()))
                self.dir = d
                return self
            except FileExistsError:
                pass
            owner = None
            try:
                owner = int(open(os.path.join(d, "pid")).read().strip())
            except (OSError, ValueError):
                pass
            stale = False
            if owner is not None:
                try:
                    os.kill(owner, 0)
                except ProcessLookupError:
                    stale = True
                except PermissionError:
                    pass
            else:    # owner died right after mkdir, before writing its pid: stale once a few seconds old
                try:
                    stale = time.time() - os.stat(d).st_mtime > 5
                except OSError:
                    stale = False
            if stale:
                gone = "%s.stale.%d" % (d, os.getpid())
                try:
                    os.rename(d, gone)                      # atomic: only one process can take it over
                    shutil.rmtree(gone, ignore_errors=True)
                except OSError:
                    pass
                continue
            if time.time() > end:
                print("queue is busy (lock held by pid %s); try again" % owner, file=sys.stderr)
                sys.exit(4)
            time.sleep(0.01 + random.random() * 0.02)

    def __exit__(self, *a):
        try:
            os.unlink(os.path.join(self.dir, "pid"))
            os.rmdir(self.dir)
        except OSError:
            pass


def path_for(seq, status):
    return os.path.join(QDIR, "%08d.%s.json" % (seq, status))


def write_job(job):
    """Atomic write of job under its current status name; removes other-status copies."""
    final = path_for(job["id"], job["status"])
    tmp = final + ".tmp"
    with open(tmp, "w") as f:
        json.dump(job, f, ensure_ascii=False, indent=1)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, final)
    for st in STATUSES:
        if st != job["status"]:
            try:
                os.unlink(path_for(job["id"], st))
            except FileNotFoundError:
                pass


def load_all(repair=True):
    """All jobs sorted by id. If a crash left two files for one id, the newest wins.
    repair=False (used by the Web UI): read-only, never deletes anything."""
    best = {}
    try:
        names = os.listdir(QDIR)
    except FileNotFoundError:
        return []
    for n in names:
        if n.endswith(".tmp"):
            if repair:
                try:
                    os.unlink(os.path.join(QDIR, n))
                except OSError:
                    pass
            continue
        m = NAME_RE.match(n)
        if not m:
            continue
        try:
            with open(os.path.join(QDIR, n)) as f:
                j = json.load(f)
        except (OSError, ValueError):
            continue
        i = int(m.group(1))
        if i not in best or j.get("updated", 0) >= best[i][0].get("updated", 0):
            if i in best and repair:
                try:
                    os.unlink(os.path.join(QDIR, best[i][1]))
                except OSError:
                    pass
            best[i] = (j, n)
        elif repair:
            try:
                os.unlink(os.path.join(QDIR, n))
            except OSError:
                pass
    return [best[i][0] for i in sorted(best)]


def next_seq():
    p = os.path.join(QDIR, ".seq")
    try:
        with open(p) as f:
            n = int(f.read().strip() or 0)
    except (OSError, ValueError):
        n = 0
        for j in load_all():
            n = max(n, j["id"])
    n += 1
    tmp = p + ".tmp"
    with open(tmp, "w") as f:
        f.write(str(n))
    os.replace(tmp, p)
    return n


def norm_url(u):
    """Canonical key so the same video shared in different forms is one job."""
    s = urlsplit(u.strip())
    host = (s.hostname or "").lower()
    if host.startswith("www."):
        host = host[4:]
    path = s.path.rstrip("/")
    m = re.search(r"/video/(\d{10,})", path)
    if "tiktok.com" in host and m:
        return "tiktok:" + m.group(1)
    if host in ("youtu.be",) and path:
        return "youtube:" + path.lstrip("/").split("/")[0]
    if host.endswith("youtube.com"):
        q = dict(parse_qsl(s.query))
        if q.get("v"):
            return "youtube:" + q["v"]
        m = re.match(r"^/(shorts|live|embed)/([\w-]+)", path)
        if m:
            return "youtube:" + m.group(2)
    q = sorted((k, v) for k, v in parse_qsl(s.query, keep_blank_values=True)
               if k.lower() not in TRACKING and not k.lower().startswith("utm_"))
    return "url:" + urlunsplit((s.scheme.lower(), host + (":%d" % s.port if s.port else ""),
                                path, urlencode(q), ""))


def file_key(p):
    st = os.stat(p)
    return "file:%s|%d|%d" % (os.path.realpath(p), st.st_size, st.st_mtime_ns)


def die(msg, code):
    print(msg, file=sys.stderr)
    sys.exit(code)


def cmd_add(a):
    if a.url:
        v = a.url.strip()
        if not re.match(r"^https?://\S+$", v) or any(c in v for c in "\t\r\n"):
            die("bad URL (must start with http:// or https://, no spaces)", 2)
        typ, key, keep = "url", norm_url(v), False
        for x in a.arg or []:
            if any(c in x for c in "\t\r\n\x1f"):
                die("bad extra option (tab/newline not allowed)", 2)
    else:
        v = a.file
        if not os.path.isabs(v) or any(c in v for c in "\t\r\n"):
            die("file path must be absolute (no tabs/newlines)", 2)
        if not os.path.isfile(v):
            die("file not found: " + v, 2)
        typ, key, keep = "file", file_key(v), not a.consume   # --consume: delete original after verified output
    with Locked():
        jobs = load_all()
        for j in jobs:
            if j["key"] != key:
                continue
            if j["status"] in ("pending", "running"):
                print("duplicate: job %d already %s" % (j["id"], j["status"]))
                sys.exit(3)
            if j["status"] == "done" and not a.force:
                print("duplicate: job %d already done (use --force to repeat)" % j["id"])
                sys.exit(3)
            if j["status"] == "failed":      # re-adding a failed job retries it, same place in history
                j.update(status="pending", attempts=0, error="", updated=now())
                write_job(j)
                print("requeued failed job %d" % j["id"])
                return
        job = dict(id=next_seq(), type=typ, value=v, key=key, keep_original=keep,
                   status="pending", attempts=0, error="", output="",
                   args=list(a.arg or []) if typ == "url" else [],
                   created=now(), updated=now())
        write_job(job)
        print("queued job %d (%d ahead)" % (job["id"], sum(1 for j in jobs if j["status"] in ("pending", "running"))))


def cmd_next(a):
    with Locked():
        for j in load_all():
            if j["status"] == "running":     # one at a time: never hand out a second job
                sys.exit(1)
        for j in load_all():
            if j["status"] == "pending":
                j.update(status="running", attempts=j["attempts"] + 1, updated=now())
                write_job(j)
                print("%d\t%s\t%d\t%s\t%s" % (j["id"], j["type"], 1 if j["keep_original"] else 0, j["value"],
                                              "\x1f".join(j.get("args", []))))
                return
    sys.exit(1)


def _get(i):
    for j in load_all():
        if j["id"] == i:
            return j
    die("no such job: %d" % i, 1)


def cmd_done(a):
    with Locked():
        j = _get(a.id)
        j.update(status="done", output=a.output or "", error="", updated=now())
        write_job(j)


def cmd_fail(a):
    with Locked():
        j = _get(a.id)
        j.update(status="failed", error=(a.message or "failed")[:500], updated=now())
        write_job(j)


def cmd_requeue(a):   # graceful stop: give the job back without counting an attempt
    with Locked():
        j = _get(a.id)
        if j["status"] == "running":
            j.update(status="pending", attempts=max(0, j["attempts"] - 1), updated=now())
            write_job(j)


def cmd_recover(a):
    """Called by the worker at start (it holds the worker lock): anything still 'running' was interrupted."""
    n = f = pr = 0
    with Locked():
        for j in load_all():
            if j["status"] == "running":
                if j["attempts"] >= MAX_ATTEMPTS:
                    j.update(status="failed", error="interrupted %d times; giving up" % j["attempts"], updated=now())
                    f += 1
                else:
                    j.update(status="pending", updated=now())
                    n += 1
                write_job(j)
            elif j["status"] == "done" and now() - j["updated"] > KEEP_DONE_DAYS * 86400:
                os.unlink(path_for(j["id"], "done"))
                pr += 1
    print("recovered=%d gave_up=%d pruned=%d" % (n, f, pr))


def cmd_retry(a):
    with Locked():
        c = 0
        for j in load_all():
            if j["status"] == "failed" and (a.all or j["id"] == a.id):
                j.update(status="pending", attempts=0, error="", updated=now())
                write_job(j)
                c += 1
    print("requeued %d" % c)
    sys.exit(0 if c else 1)


def cmd_remove(a):
    with Locked():
        j = _get(a.id)
        if j["status"] == "running":
            die("job is running; stop the worker first", 2)
        os.unlink(path_for(j["id"], j["status"]))


def cmd_clear(a):
    c = 0
    with Locked():
        for j in load_all():
            if j["status"] in a.statuses:
                os.unlink(path_for(j["id"], j["status"]))
                c += 1
    print("removed %d" % c)


def cmd_list(a):
    jobs = [j for j in load_all(repair=False) if not a.status or j["status"] == a.status]   # readers never delete files
    if a.json:
        print(json.dumps(jobs, ensure_ascii=False))
        return
    for j in jobs:
        v = j["value"] if len(j["value"]) < 60 else j["value"][:57] + "..."
        print("%4d %-8s %-4s %s%s" % (j["id"], j["status"], j["type"], v,
                                      ("  !! " + j["error"]) if j["error"] else ""))


def cmd_stats(a):
    c = {s: 0 for s in STATUSES}
    for j in load_all(repair=False):
        c[j["status"]] += 1
    if a.json:
        print(json.dumps(c))
    else:
        print(" ".join("%s=%d" % (s, c[s]) for s in STATUSES))


def cmd_selftest(a):
    """Checks the queue's filesystem needs IN THE FOLDER WHERE THE REAL QUEUE LIVES, using a throw-away
    queue next to it (deleted afterwards). Run it on the phone: q selftest"""
    import subprocess
    d = os.path.join(os.path.dirname(QDIR), "selftest.%d" % os.getpid())
    q = os.path.join(d, "queue")
    res = []

    def t(name, ok, info=""):
        res.append(bool(ok))
        print(("  ok:   " if ok else "  FAIL: ") + name + ((" [" + str(info)[:150] + "]") if (info and not ok) else ""))

    env = dict(os.environ, QUEUE_DIR=q, QUEUE_LOCK_TIMEOUT="20")
    me = os.path.abspath(__file__)

    def run(*args):
        return subprocess.run([sys.executable, me, *args], env=env, capture_output=True, text=True)

    print("Queue selftest in: %s" % os.path.dirname(QDIR))
    try:
        os.makedirs(d, exist_ok=True)
        p = os.path.join(d, "a.tmp")
        with open(p, "w") as f:
            f.write("x"); f.flush(); os.fsync(f.fileno())
        os.replace(p, os.path.join(d, "a"))
        t("write + fsync + atomic rename", os.path.exists(os.path.join(d, "a")) and not os.path.exists(p))
        os.mkdir(os.path.join(d, "lk"))
        try:
            os.mkdir(os.path.join(d, "lk")); second = True
        except FileExistsError:
            second = False
        t("mkdir is exclusive (lock primitive)", not second)
        ps = [subprocess.Popen([sys.executable, me, "add", "--url", "https://selftest.invalid/v%d" % i], env=env,
                               stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True) for i in range(10)]
        errs = [x.communicate()[1] for x in ps]
        st = run("stats").stdout.strip()
        t("10 parallel adds -> 10 jobs", st.startswith("pending=10"), st + " " + "".join(errs))
        ps = [subprocess.Popen([sys.executable, me, "add", "--url", "https://selftest.invalid/same"], env=env,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) for _ in range(6)]
        [x.wait() for x in ps]
        t("6 parallel adds of the SAME link -> 1 job", run("stats").stdout.startswith("pending=11"), run("stats").stdout)
        order = []
        for _ in range(3):
            r = run("next")
            if r.returncode == 0:
                jid = int(r.stdout.split("\t")[0]); order.append(jid); run("done", str(jid))
        t("jobs come out in FIFO order", order == [1, 2, 3], order)
        r = run("next"); run("recover")
        t("interrupted job is put back (recover)", run("stats").stdout.startswith("pending=8"), run("stats").stdout)
        fn = os.path.join(d, "clip \u00e9 1.mp4")
        open(fn, "wb").write(b"0")
        r = run("add", "--file", fn)
        t("file name with spaces/accents accepted", r.returncode == 0, r.stdout + r.stderr)
        r = run("list", "--json")
        try:
            n = len(json.loads(r.stdout))
        except ValueError:
            n = -1
        t("job list readable as JSON (Web UI)", n == 12, n)
    except Exception as e:  # noqa
        t("selftest crashed", False, repr(e))
    finally:
        shutil.rmtree(d, ignore_errors=True)
    bad = res.count(False)
    print("SELFTEST %s (%d/%d ok)" % ("PASS" if not bad else "FAIL", len(res) - bad, len(res)))
    sys.exit(1 if bad else 0)


def main():
    p = argparse.ArgumentParser(prog="qctl", description="Persistent FIFO job queue")
    s = p.add_subparsers(dest="cmd", required=True)
    x = s.add_parser("add"); g = x.add_mutually_exclusive_group(required=True)
    g.add_argument("--url"); g.add_argument("--file"); x.add_argument("--force", action="store_true")
    x.add_argument("--consume", action="store_true", help="file jobs: delete the original after a verified output")
    x.add_argument("--arg", action="append", help="extra yt-dlp option (repeatable, URL jobs only)"); x.set_defaults(f=cmd_add)
    s.add_parser("next").set_defaults(f=cmd_next)
    x = s.add_parser("done"); x.add_argument("id", type=int); x.add_argument("--output"); x.set_defaults(f=cmd_done)
    x = s.add_parser("fail"); x.add_argument("id", type=int); x.add_argument("message", nargs="?"); x.set_defaults(f=cmd_fail)
    x = s.add_parser("requeue"); x.add_argument("id", type=int); x.set_defaults(f=cmd_requeue)
    s.add_parser("recover").set_defaults(f=cmd_recover)
    s.add_parser("selftest").set_defaults(f=cmd_selftest)
    x = s.add_parser("retry"); x.add_argument("id", type=int, nargs="?"); x.add_argument("--all", action="store_true"); x.set_defaults(f=cmd_retry)
    x = s.add_parser("remove"); x.add_argument("id", type=int); x.set_defaults(f=cmd_remove)
    x = s.add_parser("clear"); x.add_argument("statuses", nargs="*", default=["done"]); x.set_defaults(f=cmd_clear)
    x = s.add_parser("list"); x.add_argument("--status", choices=STATUSES); x.add_argument("--json", action="store_true"); x.set_defaults(f=cmd_list)
    x = s.add_parser("stats"); x.add_argument("--json", action="store_true"); x.set_defaults(f=cmd_stats)
    a = p.parse_args()
    if a.cmd == "retry" and not a.all and a.id is None:
        die("retry needs an ID or --all", 2)
    try:
        a.f(a)
    except OSError as e:     # storage problem: one clear line, never a traceback
        die("queue storage error: %s  (check with: q selftest)" % e, 4)


if __name__ == "__main__":
    main()
