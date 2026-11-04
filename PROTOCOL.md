# Alfred protocol (v0)

Alfred = iOS app + `alfredd` on the box. `alfredd` is a fork of Helm's `helmd`
(/root/projects/helm/server, protocol in /root/projects/helm/PROTOCOL.md) and
keeps every helmd endpoint, auth scheme (bearer token, optional mTLS client
cert) and the session/event/WebSocket model unchanged, except where noted.

- Bind: 10.66.66.1:3341 (wg0). Token: ~/.alfred/token. State: ~/.alfred/.
- Harness registry has exactly one entry: `{"id":"alfred","name":"Alfred"}`,
  launched by `/root/.local/bin/alfred-brain` (Claude Code harness via
  claude-burst, Alfred system prompt, abliterated model; never a Claude model).
- No /box/* endpoints (Alfred is not a box remote control).

## Additions

| method | path | body | returns |
|---|---|---|---|
| POST | `/devices` | `{token, env:"sandbox"\|"production", bundle_id}` | `{ok:true}`, upsert APNs device token |
| DELETE | `/devices/{token}` | | `{ok:true}` |
| GET | `/reminders?after=<iso8601>` | | `{"reminders":[{id, title, body, fire_at, session_id?}]}`, future local notifications for the app to schedule (UNCalendarNotificationTrigger); app replaces its pending set with this list |
| POST | `/reminders` | `{title, body, fire_at, session_id?}` | `Reminder` |
| DELETE | `/reminders/{id}` | | `{ok:true}` |
| POST | `/notify` | `{title, body, session_id?}` | `{sent:int, failed:int, configured:bool}`, APNs push to all devices |
| GET | `/push/status` | | `{configured:bool, team_id?, key_id?, topic?, devices:int}` |

`fire_at` is ISO-8601 UTC (`2026-11-05T09:00:00Z`).

APNs payload: `{"aps":{"alert":{"title","body"},"sound":"default"},"session_id":"..."}`.
Tapping a notification with `session_id` opens that chat.

alfredd also pushes automatically when a session's turn finishes while no
WebSocket client is attached ("Alfred finished: <first line of reply>").

APNs config (all optional; push is a no-op with `configured:false` until set):
`~/.alfred/apns.json` = `{"team_id","key_id","p8_path","topic":"org.zyco.alfred","env":"production"}`.
Token-based JWT (ES256) over HTTP/2 to api.push.apple.com / api.sandbox.push.apple.com.
