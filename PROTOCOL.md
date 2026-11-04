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
| POST | `/notify` | `{title, body, session_id?}` | `{sent:int, failed:int, configured:bool, channel:"apns"\|"telegram"\|null}`, pushes to all devices via APNs, or Telegram if APNs isn't configured |
| GET | `/push/status` | | `{configured:bool, channel:"apns"\|"telegram"\|null, team_id?, key_id?, topic?, devices:int}` |
| GET | `/memory` | | `{text:str}`, full contents of `~/.alfred/MEMORY.md` |
| PUT | `/memory` | `{text}` | `{text}`, replaces the file wholesale (trimmed to the cap, oldest lines dropped first) |
| POST | `/memory/remember` | `{fact}` | `{text}`, appends one dated fact line, then trims |
| POST | `/outbox` | `{kind:"email", to, subject, body, attachments?:[path]}` | `OutboxItem` (status `"pending"`), also fires a `/notify` "Approval needed: <subject>" |
| GET | `/outbox?status=` | | `{outbox:[OutboxItem]}` |
| POST | `/outbox/{id}/approve` | | `OutboxItem` (status `"sent"` or `"failed"`); 403 unless the request carries `X-Alfred-Route: public` or comes from a wg0 client other than 127.0.0.1/10.66.66.1; see below |
| POST | `/outbox/{id}/reject` | | `OutboxItem` (status `"rejected"`) |

`fire_at` is ISO-8601 UTC (`2026-11-05T09:00:00Z`).

APNs payload: `{"aps":{"alert":{"title","body"},"sound":"default"},"session_id":"..."}`.
Tapping a notification with `session_id` opens that chat.

alfredd also pushes automatically when a session's turn finishes while no
WebSocket client is attached ("Alfred finished: <first line of reply>").

APNs config (all optional; push is a no-op with `configured:false` until set):
`~/.alfred/apns.json` = `{"team_id","key_id","p8_path","topic":"org.zyco.alfred","env":"production"}`.
Token-based JWT (ES256) over HTTP/2 to api.push.apple.com / api.sandbox.push.apple.com.

**Telegram fallback**: when `~/.alfred/apns.json` is absent, `/notify` (and
the auto-push on finished turns) sends via the Telegram Bot API instead, if
`~/.alfred/telegram.json` = `{"bot_token", "chat_id"}` is present. `/push/status`
reports which channel (if any) is active. Currently configured to the
"Telegram - Pardalos Bot" vault item and the owner's existing personal chat
id (the same one tsforecast/Tvbox/GrantFinder alerts already use).

**Outbox (outbound-email approval gate)**: `alfred-brain`'s own `alfred` CLI
(`server/alfred-cli.py`) can only create drafts (`alfred email draft ...`);
`approve`/`reject` are not exposed by that CLI at all, only by these two HTTP
endpoints, meant to be called from the iOS app. `POST /outbox/{id}/approve`
is additionally gated in code (`alfredd/outbox.py:check_approval_allowed`):
it 403s unless the request has header `X-Alfred-Route: public` (set by a
future reverse proxy on a public route, mirroring Helm's `X-Helm-Route`) or
`request.client.host` is a wg0 peer other than `127.0.0.1`/`10.66.66.1`, i.e.
not the box talking to itself. This stops the brain's normal local-curl tool
path from self-approving; it is a guardrail, not a security boundary (a root
process on the box could still forge the header or curl the public route
directly). On approval, alfredd sends via Gmail SMTP
(`smtp.gmail.com:465`) using the vault item "Google - Gmail App Password"
(From/login: `ennyolutogun@gmail.com`, fetched fresh via `bw-get` each send,
never cached to disk, never `work@supercriticalbooks.com`).
`OutboxItem` = `{id, kind, recipient, subject, body, attachments:[path],
status:"pending"|"sent"|"rejected"|"failed", created, decided?, sent?, error?}`.
