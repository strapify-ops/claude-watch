# Claude Watch

Apple Watch app that lists your Claude Code sessions, taps your wrist when one is **ready** or **waiting for you**, and lets you send a session a message with a chosen model and effort.

```
Claude Code (PC) -> ~/.claude/projects/*/<session>.jsonl -> watcher/claude_watch.py -> server/server.js (relay) <- long-poll <- watch app
```

- **watcher/** reads Claude Code's own session transcripts, so no Claude Code settings or hooks change. "Waiting" means Claude asked a question (AskUserQuestion), a plan is waiting for approval, the last reply ends in `?`, or a tool call has had no result for 15 s (a permission prompt).
- **server/** zero-dependency Node relay, in memory, Bearer token: `TOKEN=... node server/server.js` (port 8792).
- **ClaudeWatch/** SwiftUI watchOS 10 app (XcodeGen `project.yml`, built by GitHub Actions on macOS). The relay address is built in. To connect, double-click `Pair Claude Watch.cmd` on the PC and type the 6-digit code it shows into the watch (10 minutes, single use; 5 wrong guesses kill a code, 20 an hour shut pairing off for the hour).

**Sending messages:** open a session on the watch > Send to Claude. Pick a quick reply or dictate, and optionally a model and effort. The PC runs `claude -p --resume <id> --model <model> --effort <effort> --permission-mode <the session's own mode>`.

Nothing about models is hard-coded. The model list, each model's effort levels and its default come from Claude Code's own model catalog (`~/.claude/cache/model-catalog/`, newest fetch) on every snapshot, and each session's current model, effort and permission mode come from its transcript. The PC re-checks every choice against that live list before running. It uses the newest Claude Code the desktop app has downloaded, because an older `claude` on PATH may not support current models (set `CLAUDE_BIN` to override). Fast mode is not offered: `claude -p` would not switch it on in testing.

Quick replies come from `watcher/quick_replies.json` if present. `--dry-run` checks commands without running Claude.

Live relay: `https://claude-watch.167-233-232-19.sslip.io` (box `/opt/claudewatch`, container `claudewatch` on `crm_default`, Caddy vhost in the CRM repo). Update it with `bash server/deploy.sh`; the first run makes the token and keeps it in `~/.claude-watch/token` on the PC and `/opt/claudewatch/.env` on the box.

The PC watcher runs as the Windows scheduled task "Claude Watch relay feed" (at logon, restarts on failure): `pythonw watcher/claude_watch.py --relay https://claude-watch.167-233-232-19.sslip.io` (token read from `~/.claude-watch/token`; `--print` for a one-off snapshot).

The token lets anyone holding it run Claude prompts on this PC in each session's own permission mode. Keep it long and private.

Limits: the watch listens while the app is open or recently used. Alerts with the app closed need APNs push from the relay. A message sent from the watch goes into the session's transcript, but a desktop-app window that already has that session open may not show it until reopened.
