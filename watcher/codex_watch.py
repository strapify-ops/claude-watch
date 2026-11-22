"""Codex Watch - PC side. Reads Codex rollout files (~/.codex/sessions/**.jsonl),
works out each recent session's state and pushes a snapshot to the relay. Also picks up
commands sent from the watch and runs them with `codex exec resume`.

States: working | waiting (Codex asked a question / a tool call has sat unanswered,
usually an approval) | ready (turn finished) | stopped (turn aborted).

Nothing about models is hard-coded: the model list, each model's reasoning efforts,
its default effort and its speed tiers come from Codex's own ~/.codex/models_cache.json
on every snapshot, and each session's current model/effort comes from its latest
turn_context. When Codex adds or drops a model, the watch follows.

Usage: python codex_watch.py --relay https://HOST --token SECRET   (push + command loop)
       python codex_watch.py --print                              (one snapshot to stdout)
Quick replies shown on the watch: optional quick_replies.json next to this file (list of strings).
"""
import argparse, glob, json, os, re, shutil, subprocess, sys, tempfile, threading, time, uuid
import urllib.request

HOME = os.path.join(os.path.expanduser("~"), ".codex")
SESSIONS = os.path.join(HOME, "sessions")
HERE = os.path.dirname(os.path.abspath(__file__))
RECENT_H = 12          # only sessions touched in the last N hours
STALL_S = 25           # tool call with no output this long = probably waiting on approval
ASK_TOOLS = ("request_user_input",)
DEFAULT_REPLIES = ["Continue", "Yes, go ahead", "No, stop", "Summarise where you are"]

def _title(text):
    t = " ".join(re.sub(r"<[^>]+>", " ", text).split())
    return t[:60]

# ---------- catalog (dynamic) ----------

def catalog():
    """Models the Codex picker shows, read fresh from Codex's own cache."""
    try:
        with open(os.path.join(HOME, "models_cache.json"), encoding="utf-8") as f:
            models = json.load(f).get("models") or []
    except (OSError, ValueError):
        return []
    out = []
    for m in sorted(models, key=lambda m: m.get("priority") or 99):
        if m.get("visibility") != "list":
            continue
        efforts = [e.get("effort") if isinstance(e, dict) else e for e in m.get("supported_reasoning_levels") or []]
        tiers = [{"id": t.get("id"), "name": t.get("name") or t.get("id")} for t in m.get("service_tiers") or [] if t.get("id")]
        out.append({"slug": m.get("slug"), "name": m.get("display_name") or m.get("slug"),
                    "efforts": [e for e in efforts if e], "defaultEffort": m.get("default_reasoning_level") or "",
                    "tiers": tiers})
    return out

def config_defaults():
    """Top-level model / model_reasoning_effort from config.toml (fallback for a session's settings)."""
    d = {}
    try:
        with open(os.path.join(HOME, "config.toml"), encoding="utf-8") as f:
            for line in f:
                if line.startswith("["):
                    break
                m = re.match(r'\s*(model|model_reasoning_effort)\s*=\s*"([^"]*)"', line)
                if m:
                    d[m.group(1)] = m.group(2)
    except OSError:
        pass
    return d

def quick_replies():
    try:
        with open(os.path.join(HERE, "quick_replies.json"), encoding="utf-8") as f:
            r = json.load(f)
        return [str(x)[:80] for x in r if str(x).strip()][:12]
    except (OSError, ValueError):
        return DEFAULT_REPLIES

# ---------- sessions ----------

def read_session(path, defaults):
    s = {"id": os.path.basename(path)[-41:-6], "title": "", "cwd": "", "state": "ready", "detail": "",
         "updated": os.path.getmtime(path), "model": defaults.get("model", ""),
         "effort": defaults.get("model_reasoning_effort", "")}
    pending = {}
    last = None
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            try:
                o = json.loads(line)
            except ValueError:
                continue
            p = o.get("payload") or {}
            kind, sub = o.get("type"), p.get("type")
            if kind == "session_meta":
                s["id"] = p.get("id", s["id"]); s["cwd"] = p.get("cwd", "")
            elif kind == "turn_context":
                s["model"] = p.get("model") or s["model"]; s["effort"] = p.get("effort") or s["effort"]
                s["cwd"] = p.get("cwd") or s["cwd"]
            elif kind == "response_item" and sub == "message" and p.get("role") == "user" and not s["title"]:
                for c in p.get("content") or []:
                    txt = (c.get("text") or "").strip()
                    if txt and txt[0] not in "<#":
                        s["title"] = _title(txt); break
            elif kind == "response_item" and sub in ("function_call", "custom_tool_call"):
                pending[p.get("call_id")] = p.get("name", "")
            elif kind == "response_item" and sub in ("function_call_output", "custom_tool_call_output"):
                pending.pop(p.get("call_id"), None)
            elif kind == "event_msg" and sub == "task_started":
                last = ("working", ""); pending.clear()
            elif kind == "event_msg" and sub == "task_complete":
                last = ("ready", _title((p.get("last_agent_message") or "").strip())); pending.clear()
            elif kind == "event_msg" and sub == "turn_aborted":
                last = ("stopped", ""); pending.clear()
    state, detail = last or ("ready", "")
    if state == "working" and pending:
        name = next(iter(pending.values()))
        idle = time.time() - s["updated"]
        if any(a in name for a in ASK_TOOLS):
            state, detail = "waiting", "Codex asked you a question"
        elif idle > STALL_S:
            state, detail = "waiting", f"Needs approval? ({name} waiting {int(idle)}s)"
    if state == "ready" and detail.endswith("?"):
        state = "waiting"
    if not s["title"]:
        s["title"] = os.path.basename(s["cwd"]) or "Codex session"
    s.update(state=state, detail=detail)
    return s

def sessions():
    cutoff = time.time() - RECENT_H * 3600
    defaults = config_defaults()
    files = [f for f in glob.glob(os.path.join(SESSIONS, "**", "*.jsonl"), recursive=True)
             if os.path.getmtime(f) > cutoff]
    out = [read_session(f, defaults) for f in files]
    out.sort(key=lambda s: ({"waiting": 0, "ready": 1, "working": 2, "stopped": 3}[s["state"]], -s["updated"]))
    return out[:20]

# ---------- commands ----------

RESULTS = []            # newest first, shown on the watch
RESULTS_LOCK = threading.Lock()

def _result(cmd_id, session, status, message):
    with RESULTS_LOCK:
        for r in RESULTS:
            if r["id"] == cmd_id:
                r.update(status=status, message=message[:300], at=time.time()); break
        else:
            RESULTS.insert(0, {"id": cmd_id, "session": session, "status": status, "message": message[:300], "at": time.time()})
        del RESULTS[20:]

def build_args(cmd, sess, cat, codex):
    """Validate the watch's choices against the LIVE catalog and build the codex command line."""
    args = [codex, "exec", "resume", sess["id"]]
    model = cmd.get("model") or ""
    info = next((m for m in cat if m["slug"] == model), None)
    if model:
        if not info:
            raise ValueError(f"model {model} is not in Codex's model list")
        args += ["-m", model]
    effort = cmd.get("effort") or ""
    if effort:
        allowed = (info or next((m for m in cat if m["slug"] == sess.get("model")), None) or {}).get("efforts")
        if allowed and effort not in allowed:
            raise ValueError(f"effort {effort} not supported by {model or sess.get('model')}")
        args += ["-c", f'model_reasoning_effort="{effort}"']
    tier = cmd.get("tier") or ""
    if tier:
        tiers = [t["id"] for t in (info or {}).get("tiers", [])]
        if tier not in tiers:
            raise ValueError(f"speed tier {tier} not offered for this model")
        args += ["-c", f'service_tier="{tier}"']
    return args

def run_command(cmd, all_sessions, dry_run=False):
    cmd_id, sid = cmd.get("id") or str(uuid.uuid4()), cmd.get("session", "")
    sess = next((s for s in all_sessions if s["id"] == sid), None)
    if not sess:
        return _result(cmd_id, sid, "failed", "Session not found on the PC (older than %dh?)" % RECENT_H)
    if sess["state"] == "working":
        return _result(cmd_id, sid, "failed", "Session is busy - wait for it to finish")
    codex = shutil.which("codex")
    if not codex:
        return _result(cmd_id, sid, "failed", "codex CLI not found on PATH")
    try:
        args = build_args(cmd, sess, catalog(), codex)
    except ValueError as e:
        return _result(cmd_id, sid, "failed", str(e))
    if dry_run:
        return _result(cmd_id, sid, "dry-run", " ".join(args[1:]) + " <prompt>")
    _result(cmd_id, sid, "running", "Sent to Codex")

    def work():
        out = os.path.join(tempfile.gettempdir(), f"codex-watch-{cmd_id}.txt")
        try:
            p = subprocess.run(args + ["-o", out, "-"], input=cmd["prompt"], text=True, encoding="utf-8",
                               cwd=sess["cwd"] if os.path.isdir(sess["cwd"]) else None,
                               capture_output=True, timeout=3600)
            msg = open(out, encoding="utf-8").read().strip() if os.path.exists(out) else ""
            if p.returncode == 0:
                _result(cmd_id, sid, "done", _title(msg) or "Done")
            else:
                _result(cmd_id, sid, "failed", (p.stderr or p.stdout or "codex exited %d" % p.returncode).strip()[-300:])
        except Exception as e:
            _result(cmd_id, sid, "failed", str(e))
        finally:
            try: os.remove(out)
            except OSError: pass
    threading.Thread(target=work, daemon=True).start()

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

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--relay"); ap.add_argument("--token", default=os.environ.get("CODEX_WATCH_TOKEN", ""))
    ap.add_argument("--print", action="store_true"); ap.add_argument("--every", type=float, default=3)
    ap.add_argument("--dry-run", action="store_true", help="validate commands but do not run codex")
    a = ap.parse_args()
    if a.print or not a.relay:
        json.dump(snapshot(sessions()), sys.stdout, indent=1); return
    prev, beat = None, 0
    while True:
        try:
            sess = sessions()
            for cmd in call(a.relay, a.token, "/api/commands").get("commands", []):
                run_command(cmd, sess, a.dry_run)
            snap = snapshot(sess)
            key = json.dumps([[(s["id"], s["state"], s["detail"], s["model"], s["effort"]) for s in sess],
                              snap["catalog"], [(r["id"], r["status"]) for r in snap["results"]], snap["quickReplies"]])
            if key != prev or time.time() - beat > 60:   # heartbeat so the watch knows the PC is alive
                call(a.relay, a.token, "/api/sessions", snap); prev, beat = key, time.time()
        except Exception as e:
            print("relay error:", e, file=sys.stderr)
        time.sleep(a.every)

if __name__ == "__main__":
    main()
