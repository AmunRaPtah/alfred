#!/usr/bin/env python3
"""`alfred`: CLI for alfred-brain to talk to its own alfredd backend over
the local Alfred protocol API (10.66.66.1:3341). Installed at
/root/.local/bin/alfred-tool and symlinked to `alfred` on PATH; source of
truth is this file in the repo (server/alfred-cli.py).

Deliberately missing: `approve`/`reject` for outbox items. Those exist only
as HTTP endpoints the owner's app calls; see server/alfredd/outbox.py and
PROTOCOL.md. This CLI can create drafts, never send them.

Auth: ~/.alfred/token (same bearer token alfredd generates for itself).
"""
import argparse
import json
import sys
from pathlib import Path

import httpx

ALFRED_HOME = Path.home() / ".alfred"
BASE_URL = "http://10.66.66.1:3341"


def _token() -> str:
    tf = ALFRED_HOME / "token"
    if not tf.exists():
        print(f"error: no token at {tf}", file=sys.stderr)
        sys.exit(1)
    return tf.read_text().strip()


def _client() -> httpx.Client:
    return httpx.Client(base_url=BASE_URL, headers={"authorization": f"Bearer {_token()}"},
                         timeout=15)


def _ok(resp: httpx.Response) -> dict:
    if resp.status_code >= 400:
        print(f"error: {resp.status_code} {resp.text}", file=sys.stderr)
        sys.exit(1)
    return resp.json()


def cmd_remind(args):
    with _client() as c:
        body = {"title": args.title, "body": args.body or "", "fire_at": args.when}
        r = _ok(c.post("/reminders", json=body))
    print(json.dumps(r))


def cmd_reminders(args):
    with _client() as c:
        r = _ok(c.get("/reminders"))
    for rem in r["reminders"]:
        print(f"{rem['id']}  {rem['fire_at']}  {rem['title']}")


def cmd_unremind(args):
    with _client() as c:
        _ok(c.delete(f"/reminders/{args.id}"))
    print("ok")


def cmd_notify(args):
    with _client() as c:
        r = _ok(c.post("/notify", json={"title": args.title, "body": args.body}))
    print(json.dumps(r))


def cmd_remember(args):
    with _client() as c:
        _ok(c.post("/memory/remember", json={"fact": args.fact}))
    print("ok")


def cmd_memory(args):
    with _client() as c:
        r = _ok(c.get("/memory"))
    print(r["text"], end="")


def cmd_email_draft(args):
    with _client() as c:
        body = {"kind": "email", "to": args.to, "subject": args.subject, "body": args.body,
                "attachments": args.attach or []}
        r = _ok(c.post("/outbox", json=body))
    print(json.dumps(r))
    print("Draft created, pending owner approval in the app. This CLI cannot approve it.",
          file=sys.stderr)


def cmd_outbox(args):
    with _client() as c:
        r = _ok(c.get("/outbox", params={"status": args.status} if args.status else {}))
    for item in r["outbox"]:
        print(f"{item['id']}  {item['status']:9}  {item['recipient']:30}  {item['subject']}")


def main():
    p = argparse.ArgumentParser(prog="alfred", description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)

    r = sub.add_parser("remind", help="create a reminder")
    r.add_argument("when", help="ISO-8601 UTC fire time, e.g. 2026-11-05T09:00:00Z")
    r.add_argument("title")
    r.add_argument("body", nargs="?", default="")
    r.set_defaults(func=cmd_remind)

    sub.add_parser("reminders", help="list reminders").set_defaults(func=cmd_reminders)

    u = sub.add_parser("unremind", help="delete a reminder by id")
    u.add_argument("id")
    u.set_defaults(func=cmd_unremind)

    n = sub.add_parser("notify", help="send a push notification (APNs or Telegram fallback)")
    n.add_argument("title")
    n.add_argument("body")
    n.set_defaults(func=cmd_notify)

    rm = sub.add_parser("remember", help="append a fact to cross-session memory")
    rm.add_argument("fact")
    rm.set_defaults(func=cmd_remember)

    sub.add_parser("memory", help="print cross-session memory").set_defaults(func=cmd_memory)

    e = sub.add_parser("email", help="email actions")
    esub = e.add_subparsers(dest="email_cmd", required=True)
    ed = esub.add_parser("draft", help="create a pending email draft (needs owner approval)")
    ed.add_argument("--to", required=True)
    ed.add_argument("--subject", required=True)
    ed.add_argument("--body", required=True)
    ed.add_argument("--attach", action="append", help="path to attach; repeatable")
    ed.set_defaults(func=cmd_email_draft)

    o = sub.add_parser("outbox", help="list drafted/sent/rejected outbox items")
    o.add_argument("--status", choices=["pending", "sent", "rejected", "failed"])
    o.set_defaults(func=cmd_outbox)

    args = p.parse_args()
    try:
        args.func(args)
    except httpx.ConnectError as e:
        print(f"error: can't reach alfredd at {BASE_URL}: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
