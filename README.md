# Codex Watch

Apple Watch app that lists your Codex sessions and taps your wrist when one is **ready** or **waiting for you**.

```
Codex (PC) -> ~/.codex/sessions/*.jsonl -> watcher/codex_watch.py -> server/server.js (relay) <- long-poll <- watch app
```

- **watcher/** reads Codex's own rollout logs, so Codex's config is untouched. Codex does not log approval prompts, so "waiting" means: Codex asked a question (`request_user_input`), its final reply ends in `?`, or a tool call has had no result for 25 s (usually an approval).
- **server/** zero-dependency Node relay, in memory, Bearer token: `TOKEN=... node server/server.js` (port 8792).
- **CodexWatch/** SwiftUI watchOS 10 app (XcodeGen `project.yml`, CI on macOS). Enter relay URL + token in Settings on the watch.

**Sending commands:** open a session on the watch > Send to Codex. Pick a quick reply or dictate, and optionally a model, effort and speed. The PC runs `codex exec resume <id> -m <model> -c model_reasoning_effort=... -c service_tier=...`. The model list, each model's efforts and default, and the speed tiers are read fresh from `~/.codex/models_cache.json` on every snapshot, and each session's current model/effort comes from its latest `turn_context`. The PC re-checks every choice against that live list before running. Quick replies come from `watcher/quick_replies.json` if present. `--dry-run` checks commands without running Codex.

The token lets anyone holding it run Codex prompts on this PC. Keep it long and private.

Watcher: `python watcher/codex_watch.py --relay https://RELAY --token TOKEN` (`--print` for a one-off snapshot).

Limit: the watch listens while the app is open or recently foregrounded. Alerts with the app closed need APNs push from the relay (needs the paid developer account).
