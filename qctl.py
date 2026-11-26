#!/usr/bin/env python3
"""qctl.py - Atomic persistent FIFO job queue for Termux shared storage (stdlib only)."""
import argparse
import json
import os
import random
import re
import shutil
import sys
import time
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

HERE = os.path.dirname(os.path.abspath(__file__))
QDIR = os.environ.get("QUEUE_DIR") or os.path.join(HERE, "data", "queue")
MAX_ATTEMPTS = int(os.environ.get("QUEUE_MAX_ATTEMPTS", "3"))
KEEP_DONE_DAYS = int(os.environ.get("QUEUE_KEEP_DONE_DAYS", "14"))
STATUSES = ("pending", "running", "done", "failed")
TRACKING = {
    "si", "feature", "igshid", "is_from_webapp", "sender_device", "web_id",
    "fbclid", "gclid", "share_app_id", "share_link_id", "_r", "_t", "checksum",
    "pp", "mibextid", "rdid", "share_url",
}
NAME_RE = re.compile(r"^(\d{8})\.(pending|running|done|failed)\.json$")


def now():
    return time.time()


class Locked:
    """Exclusive atomic mkdir lock (safe on Android /storage/emulated/0 without flock)."""
    TIMEOUT = float(os.environ.get("QUEUE_LOCK_TIMEOUT", "30"))

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
            else:
                try:
                    stale = time.time() - os.stat(d).st_mtime > 5
                except OSError:
                    stale = False

            if stale:
                gone = f"{d}.stale.{os.getpid()}"
                try:
                    os.rename(d, gone)
                    shutil.rmtree(gone, ignore_errors=True)
                except OSError:
                    pass
                continue

            if time.time() > end:
                print(f"queue is busy (lock held by pid {owner}); try again", file=sys.stderr)
                sys.exit(4)
            time.sleep(0.01 + random.random() * 0.02)

    def __exit__(self, *args):
        try:
            os.unlink(os.path.join(self.dir, "pid"))
            os.rmdir(self.dir)
        except OSError:
            pass


def path_for(seq, status):
    return os.path.join(QDIR, f"{seq:08d}.{status}.json")


def write_job(job):
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
    """Canonical deduplication key across TikTok, YouTube, and Facebook share links."""
    s = urlsplit(u.strip())
    host = (s.hostname or "").lower()
    for prefix in ("www.", "m.", "mobile.", "web."):
        if host.startswith(prefix):
            host = host[len(prefix):]
    path = s.path.rstrip("/")

    if "tiktok.com" in host:
        m = re.search(r"/video/(\d{10,})", path)
        if m:
            return "tiktok:" + m.group(1)

    if host == "youtu.be" and path:
        return "youtube:" + path.lstrip("/").split("/")[0]
    if host.endswith("youtube.com"):
        q = dict(parse_qsl(s.query))
        if q.get("v"):
            return "youtube:" + q["v"]
        m = re.match(r"^/(shorts|live|embed)/([\w-]+)", path)
        if m:
            return "youtube:" + m.group(2)

    if host in ("facebook.com", "fb.watch", "fb.com"):
        m = re.match(r"^/(?:share/(?:v|r)/|reel/|watch/?)([\w-]+)", path)
        if m and m.group(1):
            return "facebook:" + m.group(1)
        q = dict(parse_qsl(s.query))
        if q.get("v"):
            return "facebook:" + q["v"]

    q = sorted(
        (k, v)
        for k, v in parse_qsl(s.query, keep_blank_values=True)
        if k.lower() not in TRACKING and not k.lower().startswith("utm_")
    )
    netloc = host + (f":{s.port}" if s.port else "")
    return "url:" + urlunsplit((s.scheme.lower(), netloc, path, urlencode(q), ""))


def file_key(p):
    st = os.stat(p)
    return f"file:{os.path.realpath(p)}|{st.st_size}|{st.st_mtime_ns}"


def die(msg, code):
    print(msg, file=sys.stderr)
    sys.exit(code)


def cmd_add(a):
    if a.url:
        v = a.url.strip()
        if not re.match(r"^https?://\S+$", v) or any(c in v for c in "\t\r\n"):
            die("bad URL (must start with http:// or https://)", 2)
        typ, key, keep = "url", norm_url(v), False
        for x in a.arg or []:
            if any(c in x for c in "\t\r\n\x1f"):
                die("bad extra option", 2)
    else:
        v = a.file
        if not os.path.isabs(v) or any(c in v for c in "\t\r\n"):
            die("file path must be absolute", 2)
        if not os.path.isfile(v):
            die("file not found: " + v, 2)
        typ, key, keep = "file", file_key(v), not a.consume

    with Locked():
        jobs = load_all()
        for j in jobs:
            if j["key"] != key:
                continue
            if j["status"] in ("pending", "running"):
                print(f"duplicate: job {j['id']} already {j['status']}")
                sys.exit(3)
            if j["status"] == "done" and not a.force:
                print(f"duplicate: job {j['id']} already done (use --force to repeat)")
                sys.exit(3)
            if j["status"] == "failed":
                j.update(status="pending", attempts=0, error="", updated=now())
                write_job(j)
                print(f"requeued failed job {j['id']}")
                return

        job = dict(
            id=next_seq(),
            type=typ,
            value=v,
            key=key,
            keep_original=keep,
            status="pending",
            attempts=0,
            error="",
            output="",
            args=list(a.arg or []) if typ == "url" else [],
            created=now(),
            updated=now(),
        )
        write_job(job)
        ahead = sum(1 for j in jobs if j["status"] in ("pending", "running"))
        print(f"queued job {job['id']} ({ahead} ahead)")


def cmd_next(a):
    limit = max(1, getattr(a, "max_running", 1))
    with Locked():
        jobs = load_all()
        if sum(1 for j in jobs if j["status"] == "running") >= limit:
            sys.exit(1)
        for j in jobs:
            if j["status"] == "pending":
                j.update(status="running", attempts=j["attempts"] + 1, updated=now())
                write_job(j)
                print(
                    "%d\t%s\t%d\t%s\t%s"
                    % (j["id"], j["type"], 1 if j["keep_original"] else 0, j["value"], "\x1f".join(j.get("args", [])))
                )
                return
    sys.exit(1)


def cmd_wait(a):
    while True:
        found = next((j for j in load_all(repair=False) if j["id"] == a.id), None)
        if found is None:
            die(f"job {a.id} removed before completion", 1)
        if found["status"] == "done":
            sys.exit(0)
        if found["status"] == "failed":
            die(f"job {a.id} failed: {found.get('error') or 'failed'}", 1)
        time.sleep(0.35)


def _get(i):
    for j in load_all():
        if j["id"] == i:
            return j
    die(f"no such job: {i}", 1)


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


def cmd_requeue(a):
    with Locked():
        j = _get(a.id)
        if j["status"] == "running":
            j.update(status="pending", attempts=max(0, j["attempts"] - 1), updated=now())
            write_job(j)


def cmd_recover(a):
    n = f = pr = 0
    with Locked():
        for j in load_all():
            if j["status"] == "running":
                if j["attempts"] >= MAX_ATTEMPTS:
                    j.update(status="failed", error=f"interrupted {j['attempts']} times; giving up", updated=now())
                    f += 1
                else:
                    j.update(status="pending", updated=now())
                    n += 1
                write_job(j)
            elif j["status"] == "done" and now() - j["updated"] > KEEP_DONE_DAYS * 86400:
                os.unlink(path_for(j["id"], "done"))
                pr += 1
    print(f"recovered={n} gave_up={f} pruned={pr}")


def cmd_retry(a):
    with Locked():
        c = 0
        for j in load_all():
            if j["status"] == "failed" and (a.all or j["id"] == a.id):
                j.update(status="pending", attempts=0, error="", updated=now())
                write_job(j)
                c += 1
    print(f"requeued {c}")
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
    print(f"removed {c}")


def cmd_list(a):
    jobs = [j for j in load_all(repair=False) if not a.status or j["status"] == a.status]
    for j in jobs:
        v = j["value"] if len(j["value"]) < 60 else j["value"][:57] + "..."
        err = f"  !! {j['error']}" if j["error"] else ""
        print(f"{j['id']:4d} {j['status']:<8s} {j['type']:<4s} {v}{err}")


def cmd_stats(a):
    c = {s: 0 for s in STATUSES}
    for j in load_all(repair=False):
        c[j["status"]] += 1
    print(" ".join(f"{s}={c[s]}" for s in STATUSES))


def cmd_selftest(a):
    import subprocess
    d = os.path.join(os.path.dirname(QDIR), f"selftest.{os.getpid()}")
    q = os.path.join(d, "queue")
    env = dict(os.environ, QUEUE_DIR=q, QUEUE_LOCK_TIMEOUT="20")
    me = os.path.abspath(__file__)

    def run(*args):
        return subprocess.run([sys.executable, me, *args], env=env, capture_output=True, text=True)

    try:
        os.makedirs(d, exist_ok=True)
        r = run("add", "--url", "https://www.facebook.com/share/v/123456789/?mibextid=wwXIfr")
        assert r.returncode == 0
        r2 = run("add", "--url", "https://m.facebook.com/share/v/123456789/")
        assert r2.returncode == 3
        print("SELFTEST PASS")
    except Exception as e:
        print(f"SELFTEST FAIL: {e}", file=sys.stderr)
        sys.exit(1)
    finally:
        shutil.rmtree(d, ignore_errors=True)


def main():
    p = argparse.ArgumentParser(prog="qctl", description="Persistent FIFO job queue")
    s = p.add_subparsers(dest="cmd", required=True)

    x = s.add_parser("add")
    g = x.add_mutually_exclusive_group(required=True)
    g.add_argument("--url")
    g.add_argument("--file")
    x.add_argument("--force", action="store_true")
    x.add_argument("--consume", action="store_true")
    x.add_argument("--arg", action="append")
    x.set_defaults(f=cmd_add)

    x = s.add_parser("next")
    x.add_argument("--max-running", type=int, default=1)
    x.set_defaults(f=cmd_next)

    x = s.add_parser("wait")
    x.add_argument("id", type=int)
    x.set_defaults(f=cmd_wait)

    x = s.add_parser("done")
    x.add_argument("id", type=int)
    x.add_argument("--output")
    x.set_defaults(f=cmd_done)

    x = s.add_parser("fail")
    x.add_argument("id", type=int)
    x.add_argument("message", nargs="?")
    x.set_defaults(f=cmd_fail)

    x = s.add_parser("requeue")
    x.add_argument("id", type=int)
    x.set_defaults(f=cmd_requeue)

    s.add_parser("recover").set_defaults(f=cmd_recover)
    s.add_parser("selftest").set_defaults(f=cmd_selftest)

    x = s.add_parser("retry")
    x.add_argument("id", type=int, nargs="?")
    x.add_argument("--all", action="store_true")
    x.set_defaults(f=cmd_retry)

    x = s.add_parser("remove")
    x.add_argument("id", type=int)
    x.set_defaults(f=cmd_remove)

    x = s.add_parser("clear")
    x.add_argument("statuses", nargs="*", default=["done"])
    x.set_defaults(f=cmd_clear)

    x = s.add_parser("list")
    x.add_argument("--status", choices=STATUSES)
    x.set_defaults(f=cmd_list)

    s.add_parser("stats").set_defaults(f=cmd_stats)

    a = p.parse_args()
    if a.cmd == "retry" and not a.all and a.id is None:
        die("retry needs an ID or --all", 2)
    try:
        a.f(a)
    except OSError as e:
        die(f"queue storage error: {e}", 4)


if __name__ == "__main__":
    main()