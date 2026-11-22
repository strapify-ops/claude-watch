"""Claude Watch - PC side. Reads Claude Code session transcripts
(~/.claude/projects/<project>/<session>.jsonl), works out each recent session's state and
pushes a snapshot to the relay. Also runs prompts sent from the watch with
`claude -p --resume <id>`.

States: working | waiting (Claude asked a question, a plan waits for approval, the last
reply ends in "?", or a tool call has had no result for 15 s - a permission prompt) |
ready (turn ended).

Nothing about models is hard-coded: the model list, each model's effort levels, default
effort and fast-mode support come from Claude Code's own model catalog
(~/.claude/cache/model-catalog/*.json, newest fetch) on every snapshot, and each session's
current model / effort / permission mode come from its own transcript.

Usage: python claude_watch.py --relay https://HOST --token SECRET   (push + command loop)
       python claude_watch.py --print                              (one snapshot to stdout)
Quick replies shown on the watch: optional quick_replies.json next to this file.
"""
import argparse, glob, json, os, re, shutil, subprocess, sys, threading, time, uuid
import urllib.request

CLAUDE = os.path.join(os.path.expanduser("~"), ".claude")
PROJECTS = os.path.join(CLAUDE, "projects")
HERE = os.path.dirname(os.path.abspath(__file__))
RECENT_H = 12
STALL_S = 15
REPLY_MAX = 6000      # chars of Claude's last reply sent to the watch (full detail page)
ASK_TOOLS = ("AskUserQuestion", "ExitPlanMode")
DEFAULT_REPLIES = ["Continue", "Yes, go ahead", "No, stop", "Summarise where you are"]

def _title(text):
    t = " ".join(re.sub(r"<[^>]+>", " ", text).split())
    return t[:60]

# ---------- catalog (dynamic) ----------

def catalog():
    """Models Claude Code offers this account, from its newest cached catalog fetch."""
    best, cfg = -1, {}
    for f in glob.glob(os.path.join(CLAUDE, "cache", "model-catalog", "*.json")):
        try:
            with open(f, encoding="utf-8") as fh:
                d = json.load(fh)
        except (OSError, ValueError):
            continue
        if (d.get("fetchedAt") or 0) > best:
            best, cfg = d.get("fetchedAt") or 0, (d.get("catalog") or {}).get("config") or {}
    out = []
    for m in cfg.get("models") or []:
        if m.get("hidden") or not m.get("id"):
            continue
        efforts = [e.get("id") for e in (m.get("thinking") or {}).get("effort_options") or [] if e.get("id")]
        out.append({"slug": m["id"], "name": m.get("name") or m["id"], "efforts": efforts,
                    "defaultEffort": (m.get("runtime") or {}).get("default_effort") or "",
                    # fast mode exists in the catalog, but `claude -p` ignores every way we
                    # found to switch it on (fast_mode_state stays "off"), so it is not offered
                    "tiers": [],
                    "main": m.get("section") == "main"})
    out.sort(key=lambda m: not m["main"])   # the picker's main models first
    return out

def quick_replies():
    try:
        with open(os.path.join(HERE, "quick_replies.json"), encoding="utf-8") as f:
            r = json.load(f)
        return [str(x)[:80] for x in r if str(x).strip()][:12]
    except (OSError, ValueError):
        return DEFAULT_REPLIES

# ---------- sessions ----------

def _blocks(content):
    return [b for b in content if isinstance(b, dict)] if isinstance(content, list) else []

def read_session(path, app_mode=""):
    s = {"id": os.path.basename(path)[:-6], "title": "", "cwd": "", "state": "ready", "detail": "",
         "updated": os.path.getmtime(path), "model": "", "effort": "", "mode": ""}
    pending, first_prompt, custom, last_text, last = {}, "", "", "", None
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            try:
                o = json.loads(line)
            except ValueError:
                continue
            ty = o.get("type")
            if ty == "custom-title":
                custom = o.get("customTitle") or custom
            if o.get("isSidechain") or ty not in ("user", "assistant"):
                continue
            s["cwd"] = o.get("cwd") or s["cwd"]
            msg = o.get("message") or {}
            c = msg.get("content")
            if ty == "user":
                s["mode"] = o.get("permissionMode") or s["mode"]
                results = [b for b in _blocks(c) if b.get("type") == "tool_result"]
                for b in results:
                    pending.pop(b.get("tool_use_id"), None)
                if not results:   # a real prompt from you starts a turn
                    txt = c if isinstance(c, str) else " ".join(b.get("text", "") for b in _blocks(c) if b.get("type") == "text")
                    txt = txt.strip()
                    if txt and not txt.startswith("<") and not first_prompt:
                        first_prompt = txt
                    pending.clear()
                last = "working"
            else:
                s["model"] = msg.get("model") or s["model"]
                s["effort"] = o.get("effort") or s["effort"]
                for b in _blocks(c):
                    if b.get("type") == "tool_use":
                        pending[b.get("id")] = b.get("name", "")
                    elif b.get("type") == "text" and b.get("text", "").strip():
                        last_text = b["text"].strip()
                last = "ready" if msg.get("stop_reason") == "end_turn" and not pending else "working"
    state, detail = last or "ready", ""
    if state == "ready":
        detail = _title(last_text)
        if last_text.endswith("?"):
            state = "waiting"
    elif pending:
        name = next(iter(pending.values()))
        idle = time.time() - s["updated"]
        if name in ASK_TOOLS:
            state = "waiting"
            detail = "Claude asked you a question" if name == "AskUserQuestion" else "Plan waiting for approval"
        elif idle > STALL_S and (app_mode or s["mode"]) not in ("bypassPermissions", "dontAsk"):
            # a session that never asks permission is just running a long tool, not waiting
            state, detail = "waiting", f"Permission? ({name} waiting {int(idle)}s)"
    if state == "working" and time.time() - s["updated"] > 600:
        state, detail = "stopped", "No activity for 10+ min (interrupted?)"
    s["title"] = _title(custom or first_prompt) or os.path.basename(s["cwd"]) or "Claude session"
    s.update(state=state, detail=detail, reply=last_text[:REPLY_MAX])
    return s

def app_sessions():
    """The Claude desktop app's own session records (one JSON per session). They say whether a
    session is archived, its title, permission mode and which transcript it writes to."""
    local = os.environ.get("LOCALAPPDATA") or os.path.join(os.path.expanduser("~"), "AppData", "Local")
    out = []
    for f in glob.glob(os.path.join(local, "Claude-Data", "*", "claude-code-sessions", "*", "*", "local_*.json")):
        try:
            with open(f, encoding="utf-8") as fh:
                o = json.load(fh)
        except (OSError, ValueError):
            continue
        if isinstance(o, dict):
            out.append(o)
    return out

def _transcript(cli_id):
    if not cli_id:
        return None
    hits = glob.glob(os.path.join(PROJECTS, "*", cli_id + ".jsonl"))
    return max(hits, key=os.path.getmtime) if hits else None

def sessions():
    cutoff = time.time() - RECENT_H * 3600
    meta = app_sessions()
    out = []
    if meta:
        # Only sessions the app shows: not archived, active in the last RECENT_H hours.
        for o in meta:
            if o.get("isArchived") or (o.get("lastActivityAt") or 0) / 1000 < cutoff:
                continue
            path = _transcript(o.get("lastAssistantCliSessionId") or o.get("cliSessionId"))
            if not path:
                continue
            s = read_session(path, o.get("permissionMode") or "")
            s["title"] = _title(o.get("title") or "") or s["title"]
            s["mode"] = o.get("permissionMode") or s["mode"]
            if o.get("interruptedAwaitingPerson"):
                s["state"], s["detail"] = "waiting", s["detail"] or "Waiting for you"
            out.append(s)
    else:   # no desktop app records: fall back to every recent transcript
        files = [f for f in glob.glob(os.path.join(PROJECTS, "*", "*.jsonl")) if os.path.getmtime(f) > cutoff]
        out = [read_session(f) for f in files]
    out.sort(key=lambda s: ({"waiting": 0, "ready": 1, "working": 2}.get(s["state"], 3), -s["updated"]))
    return out[:20]

# ---------- commands ----------

RESULTS = []
RESULTS_LOCK = threading.Lock()

def _result(cmd_id, session, status, message):
    with RESULTS_LOCK:
        for r in RESULTS:
            if r["id"] == cmd_id:
                r.update(status=status, message=message[:REPLY_MAX], at=time.time()); break
        else:
            RESULTS.insert(0, {"id": cmd_id, "session": session, "status": status, "message": message[:REPLY_MAX], "at": time.time()})
        del RESULTS[20:]

def build_args(cmd, sess, cat, exe):
    """Validate the watch's choices against the LIVE catalog and build the claude command line."""
    args = [exe, "-p", "--resume", sess["id"], "--output-format", "json"]
    model = cmd.get("model") or ""
    info = next((m for m in cat if m["slug"] == model), None)
    if model and not info:
        raise ValueError(f"model {model} is not in Claude Code's model list")
    if model:
        args += ["--model", model]
    ref = info or next((m for m in cat if m["slug"] == sess.get("model")), None) or {}
    effort = cmd.get("effort") or ""
    if effort:
        if ref and effort not in ref["efforts"]:
            raise ValueError(f"effort {effort} not supported by {ref['name']}")
        args += ["--effort", effort]
    if cmd.get("tier"):
        raise ValueError("fast mode cannot be set from the watch")
    if sess.get("mode"):
        args += ["--permission-mode", sess["mode"]]   # the mode the session already runs in
    return args

def _ver(path):
    m = re.search(r"claude-code[\\/](\d+)\.(\d+)\.(\d+)", path)
    return tuple(int(x) for x in m.groups()) if m else (0, 0, 0)

def find_claude():
    """Newest Claude Code the desktop app has downloaded (the npm one on PATH can be too old
    for current models), else whatever `claude` is on PATH. CLAUDE_BIN overrides."""
    if os.environ.get("CLAUDE_BIN"):
        return os.environ["CLAUDE_BIN"]
    local = os.environ.get("LOCALAPPDATA") or os.path.join(os.path.expanduser("~"), "AppData", "Local")
    found = glob.glob(os.path.join(local, "Claude-Data", "*", "claude-code", "*", "*", "claude.exe"))
    return max(found, key=_ver) if found else shutil.which("claude")

def run_command(cmd, all_sessions, dry_run=False):
    cmd_id, sid = cmd.get("id") or str(uuid.uuid4()), cmd.get("session", "")
    sess = next((s for s in all_sessions if s["id"] == sid), None)
    if not sess:
        return _result(cmd_id, sid, "failed", "Session not found on the PC (older than %dh?)" % RECENT_H)
    if sess["state"] == "working":
        return _result(cmd_id, sid, "failed", "Session is busy - wait for it to finish")
    exe = find_claude()
    if not exe:
        return _result(cmd_id, sid, "failed", "claude CLI not found on PATH")
    try:
        args = build_args(cmd, sess, catalog(), exe)
    except ValueError as e:
        return _result(cmd_id, sid, "failed", str(e))
    if dry_run:
        return _result(cmd_id, sid, "dry-run", " ".join(args[1:]) + " <prompt>")
    _result(cmd_id, sid, "running", "Sent to Claude")

    def work():
        try:
            p = subprocess.run(args, input=cmd["prompt"], text=True, encoding="utf-8", capture_output=True,
                               cwd=sess["cwd"] if os.path.isdir(sess["cwd"]) else None, timeout=3600)
            try:
                out = json.loads(p.stdout)
            except ValueError:
                out = {}
            if p.returncode == 0 and not out.get("is_error"):
                _result(cmd_id, sid, "done", (out.get("result") or "").strip() or "Done")
            else:
                err = out.get("result") or p.stderr or p.stdout or "claude exited %d" % p.returncode
                _result(cmd_id, sid, "failed", str(err).strip()[-300:])
        except Exception as e:
            _result(cmd_id, sid, "failed", str(e))
    threading.Thread(target=work, daemon=True).start()

# ---------- images in replies ----------
# Claude's replies point at pictures as Markdown images or as plain file paths
# (screenshots, contact sheets). Local files are shrunk to a watch-sized JPEG, uploaded to the
# relay under their SHA-1, and the reply is rewritten to ![name](cwimg:<sha1>) for the watch.
# http(s) image links are left as they are; the watch loads those itself.

IMG_EXT = r"(?:png|jpe?g|gif|webp|bmp)"
MD_IMG = re.compile(r"!\[([^\]]*)\]\(<?([^)>]+?)>?\)")
# lazy and allowing spaces ("Claude Files"): runs from a drive letter / root to the first image
# extension; a match that is not a real file is left alone
BARE_PATH = re.compile(r"(?<![\w(\[/!:\\])((?:[A-Za-z]:[\\/]|\\\\|~[\\/])[^`'\"<>|*?\n\[\]]+?\." + IMG_EXT + r")\b", re.I)
MD_LINK_PATH = re.compile(r"(?<!!)\[([^\]]*)\]\(<?((?:[A-Za-z]:[\\/]|/|~[\\/])[^)>]+\." + IMG_EXT + r")>?\)", re.I)
IMG_CACHE = {}       # (path, mtime) -> sha1 of the shrunk JPEG
RELAY_IMAGES = None  # ids the relay says it holds (None = not asked yet)
UPLOAD_LOCK = threading.Lock()

def _local(p):
    p = os.path.expanduser(p.strip().strip("`").replace("%20", " "))
    if p.lower().startswith("file:///"):
        p = p[8:]
    return p if os.path.isfile(p) else None

def _shrink(path):
    from PIL import Image
    import hashlib, io
    with Image.open(path) as im:
        im.seek(0)
        im = im.convert("RGB")
        im.thumbnail((900, 900))          # sharp enough to zoom 3x on a 410 px wide screen
        buf = io.BytesIO()
        im.save(buf, "JPEG", quality=72, optimize=True)
    data = buf.getvalue()
    return hashlib.sha1(data).hexdigest(), data

def _image_id(relay, token, path):
    key = (path, os.path.getmtime(path))
    sha = IMG_CACHE.get(key)
    if sha and (RELAY_IMAGES is None or sha in RELAY_IMAGES):
        return sha
    sha, data = _shrink(path)
    if relay:
        req = urllib.request.Request(relay.rstrip("/") + "/api/img/" + sha, data=data, method="PUT",
                                     headers={"Content-Type": "image/jpeg", "Authorization": "Bearer " + token})
        urllib.request.urlopen(req, timeout=20).read()
        if RELAY_IMAGES is not None:
            RELAY_IMAGES.add(sha)
    IMG_CACHE[key] = sha
    return sha

def attach_images(sess, relay, token):
    """Rewrite each reply so its pictures point at relay copies. A picture that fails stays as text."""
    def swap(path, alt):
        lp = _local(path)
        if not lp:
            return None
        try:
            with UPLOAD_LOCK:
                return f"![{alt or os.path.basename(lp)}](cwimg:{_image_id(relay, token, lp)})"
        except Exception as e:
            print("image skipped:", lp, e, file=sys.stderr)
            return None
    for s in sess:
        r = s.get("reply") or ""
        if not re.search(IMG_EXT, r, re.I):
            continue
        r = MD_IMG.sub(lambda m: swap(m.group(2), m.group(1)) or m.group(0), r)
        r = MD_LINK_PATH.sub(lambda m: swap(m.group(2), m.group(1)) or m.group(0), r)
        r = BARE_PATH.sub(lambda m: (swap(m.group(1), "") or m.group(0)), r)
        r = re.sub(r"`(!\[[^\]]*\]\(cwimg:[0-9a-f]{40}\))`", r"\1", r)   # path was in `code`
        s["reply"] = r

# ---------- relay I/O ----------

def call(relay, token, path, body=None):
    req = urllib.request.Request(relay.rstrip("/") + path, method="POST" if body is not None else "GET",
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Content-Type": "application/json", "Authorization": "Bearer " + token})
    return json.loads(urllib.request.urlopen(req, timeout=10).read() or b"{}")

def snapshot(sess):
    with RESULTS_LOCK:
        res = [dict(r) for r in RESULTS]
    return {"sessions": sess, "catalog": catalog(), "results": res, "quickReplies": quick_replies()}

def pair(relay, token):
    """Ask the relay for a one-time code and show it (console and a Windows pop-up)."""
    try:
        code = call(relay, token, "/api/pair", {}).get("code", "")
        msg = f"Pairing code: {code[:3]} {code[3:]}\n\nOn the watch: Claude Watch > Pair, type it in.\nValid for 10 minutes, once."
    except Exception as e:
        msg = f"Could not get a pairing code: {e}"
    print(msg)
    if os.name == "nt":
        import ctypes
        ctypes.windll.user32.MessageBoxW(None, msg, "Claude Watch", 0x40)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--relay", default=os.environ.get("CLAUDE_WATCH_RELAY", "")); ap.add_argument("--token", default=os.environ.get("CLAUDE_WATCH_TOKEN", ""))
    ap.add_argument("--print", action="store_true"); ap.add_argument("--every", type=float, default=3)
    ap.add_argument("--pair", action="store_true", help="show a 6-digit code to type on the watch")
    ap.add_argument("--dry-run", action="store_true", help="validate commands but do not run claude")
    a = ap.parse_args()
    if not a.token:   # deploy.sh keeps the token here
        try:
            with open(os.path.join(os.path.expanduser("~"), ".claude-watch", "token"), encoding="utf-8") as f:
                a.token = f.read().strip()
        except OSError:
            pass
    if a.pair:
        return pair(a.relay, a.token)
    if a.print or not a.relay:
        json.dump(snapshot(sessions()), sys.stdout, indent=1); return
    prev, beat = None, 0
    while True:
        try:
            sess = sessions()
            for cmd in call(a.relay, a.token, "/api/commands").get("commands", []):
                run_command(cmd, sess, a.dry_run)
            attach_images(sess, a.relay, a.token)
            snap = snapshot(sess)
            key = json.dumps([[(s["id"], s["state"], s["detail"], s["model"], s["effort"]) for s in sess],
                              snap["catalog"], [(r["id"], r["status"]) for r in snap["results"]], snap["quickReplies"]])
            if key != prev or time.time() - beat > 60:   # heartbeat so the watch knows the PC is alive
                got = call(a.relay, a.token, "/api/sessions", snap); prev, beat = key, time.time()
                global RELAY_IMAGES
                held = set(got.get("images") or [])
                if RELAY_IMAGES is not None and any(v not in held for v in IMG_CACHE.values()):
                    prev = None   # relay lost pictures (restart): re-upload on the next pass
                RELAY_IMAGES = held
        except Exception as e:
            print("relay error:", e, file=sys.stderr)
        time.sleep(a.every)

if __name__ == "__main__":
    main()
