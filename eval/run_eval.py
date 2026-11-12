#!/usr/bin/env python3
"""Backend-agnostic runner for the Alfred eval suite (tasks.py).

Usage:
  run_eval.py [--backend kqwen] [--via cli|alfredd] [--only id1,id2] [--out-prefix NAME]

--via alfredd (the default) drives each task through the live alfredd exactly
as the phone does: POST /sessions (harness alfred, cwd = the task's scratch
dir, ephemeral so it skips memory capture and push), poll its events until the
turn's `usage` event, grade the last assistant message, then purge the
session. That exercises alfred-brain, the persona + MEMORY.md prompt, the
curated skills and the long-lived stream-json session. --via cli is the old
path: a bare `claude-burst -p` with only alfred-system.md.

Backends (see BACKENDS below): qwen122-tpu needs the Kaggle TPU session already
serving on 127.0.0.1:8193. kqwen, kglm, kq122 run on the shared Kaggle
2x T4 tier via kaggle-glm; this script does NOT start/stop that session --
run.sh (or the caller) is responsible for that, so one Kaggle session can be
reused across the whole suite. Any other BACKEND name is treated as a raw
BURST_MODEL passthrough (e.g. "burst-qwen38-27b" for the always-on Modal
tier), with no system-prompt override and no Kaggle lifecycle.

Env overrides:
  ALFRED_SYSTEM_PROMPT   path to a system prompt file (default: prefer
                         /root/projects/alfred/server/alfred-system.md if it
                         exists and is non-empty, else the backend's own
                         kaggle/<backend>-system.md)
  ALFRED_EVAL_TIMEOUT    override every task's timeout (seconds)
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tasks as tasks_mod  # noqa: E402

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "server"))
# Grade what the app shows: alfredd strips leaked reasoning before replies reach the phone.
from alfredd.adapters import strip_leaked_reasoning  # noqa: E402

REPO = "/root/projects/llm-burst"
KAGGLE_DIR = os.path.join(REPO, "kaggle")
ALFRED_SYS_DEFAULT = "/root/projects/alfred/server/alfred-system.md"
SCRATCH_ROOT = "/tmp/alfred-eval"

BACKENDS = {
    "kqwen": {"burst_model": "burst-qwen38-kaggle", "kaggle_model": "qwen38-kaggle",
              "sys_file": os.path.join(KAGGLE_DIR, "kqwen-system.md"), "kaggle": True},
    "kglm": {"burst_model": "burst-glm47-kaggle", "kaggle_model": "glm47-kaggle",
             "sys_file": os.path.join(KAGGLE_DIR, "kglm-system.md"), "kaggle": True},
    "kq122": {"burst_model": "burst-qwen35-122b-kaggle", "kaggle_model": "qwen35-122b-kaggle",
              "sys_file": os.path.join(KAGGLE_DIR, "kq122-system.md"), "kaggle": True},
    "khermes": {"burst_model": "burst-qwen36-35b-kaggle", "kaggle_model": "qwen36-35b-kaggle",
                "sys_file": os.path.join(KAGGLE_DIR, "khermes-system.md"), "kaggle": True},
    # Qwen3.5-122B on a Kaggle TPU v5e-8 (llm-burst kaggle-tpu/qwen122-tpu, box
    # 127.0.0.1:8193). Its session is launched by `qwen122-tpu`, not kaggle-glm,
    # so run.sh only health-checks it.
    "qwen122-tpu": {"burst_model": "burst-qwen122-tpu", "kaggle_model": None,
                    "sys_file": None, "kaggle": False},
}


# --via alfredd: eval backend name -> alfred-brain ALFRED_BRAIN value.
ALFREDD_BRAINS = {"kbench-claude-sonnet-5": "sonnet", "sonnet": "sonnet",
                  "qwen122-tpu": "tpu", "kglm": "kglm", "khermes": "khermes",
                  "kqwen": "kqwen"}
ALFREDD_URL = os.environ.get("ALFREDD_URL", "http://10.66.66.1:3341")


def _alfredd(method, path, body=None, timeout=30):
    import urllib.request
    token = open(os.path.expanduser("~/.alfred/token")).read().strip()
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(ALFREDD_URL + path, data=data, method=method, headers={
        "Authorization": f"Bearer {token}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read() or b"null")


def run_via_alfredd(brain, scratch, prompt, timeout):
    """One task as one alfredd session. Returns (text, num_turns, is_error,
    timed_out, err, extra) where extra holds tool/cost stats."""
    meta = _alfredd("POST", "/sessions", {"harness": "alfred", "cwd": scratch,
                                          "permission": "bypass", "text": prompt,
                                          "ephemeral": True, "brain": brain})
    sid = meta["id"]
    events, after, done = [], 0, False
    t0 = time.time()
    try:
        while time.time() - t0 < timeout:
            new = _alfredd("GET", f"/sessions/{sid}/events?after={after}&limit=1000")
            if new:
                events += new
                after = new[-1].get("seq", after)
            if any(e.get("type") == "usage" for e in new):
                done = True
                break
            time.sleep(2)
    finally:
        try:
            _alfredd("DELETE", f"/sessions/{sid}?purge=1")
        except Exception:
            pass
    replies = [e["text"] for e in events if e.get("type") == "assistant" and e.get("text")]
    errors = [e.get("text", "") for e in events if e.get("type") == "error"]
    calls = [e for e in events if e.get("type") == "tool_call"]
    tool_errors = sum(1 for e in events if e.get("type") == "tool_result" and e.get("is_error"))
    usage = next((e for e in reversed(events) if e.get("type") == "usage"), {})
    extra = {"tool_calls": len(calls), "tool_errors": tool_errors,
             "tools_used": sorted({c.get("name", "?") for c in calls}),
             "cost_usd": usage.get("cost_usd"), "output_tokens": usage.get("output_tokens")}
    err = "; ".join(errors)[:300] or None
    return (replies[-1] if replies else ""), len(calls) + 1, bool(errors), not done, \
        ("timeout" if not done else err), extra


def resolve_backend(name):
    if name in BACKENDS:
        return dict(BACKENDS[name], name=name)
    # Raw passthrough: treat `name` as a BURST_MODEL value, no Kaggle
    # lifecycle, no system-prompt override (so another launcher's default
    # applies, e.g. a future TPU tier).
    return {"burst_model": name, "kaggle_model": None, "sys_file": None, "kaggle": False, "name": name}


def pick_system_prompt(backend_cfg, cwd):
    override = os.environ.get("ALFRED_SYSTEM_PROMPT")
    path = override
    if not path:
        if os.path.exists(ALFRED_SYS_DEFAULT) and os.path.getsize(ALFRED_SYS_DEFAULT) > 0:
            path = ALFRED_SYS_DEFAULT
        elif backend_cfg["sys_file"] and os.path.exists(backend_cfg["sys_file"]):
            path = backend_cfg["sys_file"]
    if not path:
        return None
    with open(path) as f:
        body = f.read()
    body += f"\n\n# Environment\n - Working directory: {cwd}\n - Today's date: {datetime.now():%Y-%m-%d}\n"
    return body, path


def run_one_task(task, backend_cfg, timeout_override=None, via="alfredd"):
    tid = task["id"]
    scratch = os.path.join(SCRATCH_ROOT, tid)
    shutil.rmtree(scratch, ignore_errors=True)
    os.makedirs(scratch, exist_ok=True)
    task["setup"](scratch)
    prompt = task["prompt"](scratch)
    timeout = timeout_override or task["timeout"]

    if via == "alfredd":
        brain = ALFREDD_BRAINS.get(backend_cfg["name"])
        if not brain:
            raise SystemExit(f"--via alfredd: no alfred-brain mapping for backend {backend_cfg['name']!r}")
        t0 = time.time()
        try:
            raw_text, num_turns, is_error, timed_out, err, extra = run_via_alfredd(
                brain, scratch, prompt, timeout)
        except Exception as e:
            raw_text, num_turns, is_error, timed_out, err, extra = "", None, True, False, str(e), {}
        wall = time.time() - t0
        if timed_out:
            passed, detail = False, "timed out before producing a result"
        else:
            try:
                passed, detail = task["check"](scratch, strip_leaked_reasoning(raw_text))
            except Exception as e:
                passed, detail = False, f"checker raised: {e}"
        return {"id": tid, "category": task["category"], "passed": bool(passed),
                "detail": detail, "wall_time_s": round(wall, 1), "num_turns": num_turns,
                "is_error": is_error, "timed_out": timed_out, "error": err,
                "system_prompt_file": "alfredd", **extra}

    sys_prompt, sys_path = (None, None)
    picked = pick_system_prompt(backend_cfg, scratch)
    if picked:
        sys_prompt, sys_path = picked

    env = dict(os.environ)
    env["BURST_MODEL"] = backend_cfg["burst_model"]
    env["DISABLE_NON_ESSENTIAL_MODEL_CALLS"] = "1"

    cmd = ["claude-burst", "-p", prompt,
           "--output-format", "json",
           "--permission-mode", "bypassPermissions",
           "--permission-prompts", "none",
           "--no-session-persistence"]
    if sys_prompt:
        cmd += ["--system-prompt", sys_prompt]

    t0 = time.time()
    timed_out = False
    err = None
    raw_text = ""
    num_turns = None
    is_error = None
    try:
        r = subprocess.run(cmd, cwd=scratch, env=env, capture_output=True,
                            text=True, timeout=timeout)
        wall = time.time() - t0
        stdout = r.stdout.strip()
        try:
            obj = json.loads(stdout)
            raw_text = obj.get("result", stdout)
            num_turns = obj.get("num_turns")
            is_error = obj.get("is_error")
        except Exception:
            raw_text = stdout
            err = f"non-JSON stdout (rc={r.returncode}); stderr_tail={r.stderr[-300:]!r}"
    except subprocess.TimeoutExpired as e:
        wall = time.time() - t0
        timed_out = True
        err = "timeout"
        raw_text = (e.stdout or "") if isinstance(e.stdout, str) else ""
    except Exception as e:
        wall = time.time() - t0
        err = str(e)

    if timed_out:
        passed, detail = False, "timed out before producing a result"
    else:
        try:
            passed, detail = task["check"](scratch, strip_leaked_reasoning(raw_text))
        except Exception as e:
            passed, detail = False, f"checker raised: {e}"

    return {
        "id": tid,
        "category": task["category"],
        "passed": bool(passed),
        "detail": detail,
        "wall_time_s": round(wall, 1),
        "num_turns": num_turns,
        "is_error": is_error,
        "timed_out": timed_out,
        "error": err,
        "system_prompt_file": sys_path,
    }


def write_outputs(args, backend_cfg, results, suite_t0, partial=False):
    suite_wall = round(time.time() - suite_t0, 1)
    date_tag = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    prefix = args.out_prefix or f"{args.backend}-{args.via}" + ("" if args.suite == "core" else f"-{args.suite}")
    out_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "results")
    os.makedirs(out_dir, exist_ok=True)
    out_json = os.path.join(out_dir, f"{prefix}-{date_tag}.json")

    summary = {
        "backend": args.backend,
        "via": args.via,
        "suite": args.suite,
        "burst_model": backend_cfg["burst_model"],
        "date_utc": date_tag,
        "partial": partial,
        "suite_wall_time_s": suite_wall,
        "n_tasks": len(results),
        "n_passed": sum(1 for r in results if r["passed"]),
        "results": results,
    }
    with open(out_json, "w") as f:
        json.dump(summary, f, indent=2)

    out_md = os.path.join(out_dir, f"{prefix}-{date_tag}.md")
    by_cat = {}
    for r in results:
        by_cat.setdefault(r["category"], []).append(r)
    title = f"# Alfred eval: {args.backend} ({backend_cfg['burst_model']}), {date_tag}"
    if partial:
        title += " (partial -- interrupted)"
    lines = [title, ""]
    lines.append(f"Overall: {summary['n_passed']}/{summary['n_tasks']} passed, "
                  f"suite wall time {suite_wall}s")
    lines.append("")
    for cat, recs in by_cat.items():
        npass = sum(1 for r in recs if r["passed"])
        lines.append(f"## {cat}: {npass}/{len(recs)}")
        for r in recs:
            mark = "PASS" if r["passed"] else "FAIL"
            lines.append(f"- [{mark}] {r['id']} ({r['wall_time_s']}s, turns={r['num_turns']}): {r['detail']}")
        lines.append("")
    with open(out_md, "w") as f:
        f.write("\n".join(lines))
    return out_json, out_md


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--backend", default="kqwen")
    ap.add_argument("--only", default=None, help="comma-separated task ids")
    ap.add_argument("--via", choices=["alfredd", "cli"], default="alfredd")
    ap.add_argument("--suite", choices=["core", "hard", "all"], default="core")
    ap.add_argument("--out-prefix", default=None)
    args = ap.parse_args()

    backend_cfg = resolve_backend(args.backend)
    timeout_override = int(os.environ["ALFRED_EVAL_TIMEOUT"]) if os.environ.get("ALFRED_EVAL_TIMEOUT") else None

    todo = tasks_mod.TASKS
    if args.suite != "all":
        todo = [t for t in todo if t.get("suite", "core") == args.suite]
    if args.only:
        wanted = set(args.only.split(","))
        todo = [t for t in todo if t["id"] in wanted]

    results = []
    suite_t0 = time.time()
    try:
        for i, task in enumerate(todo, 1):
            print(f"[{i}/{len(todo)}] {task['id']} ({task['category']}) ...", file=sys.stderr, flush=True)
            rec = run_one_task(task, backend_cfg, timeout_override, via=args.via)
            results.append(rec)
            status = "PASS" if rec["passed"] else "FAIL"
            print(f"    {status} in {rec['wall_time_s']}s turns={rec['num_turns']}: {rec['detail'][:160]}",
                  file=sys.stderr, flush=True)
            # Write after every task so a kill (budget timeout, Ctrl-C) still
            # leaves whatever ran so far on disk instead of losing it all.
            write_outputs(args, backend_cfg, results, suite_t0, partial=(i < len(todo)))
    finally:
        out_json, out_md = write_outputs(args, backend_cfg, results, suite_t0,
                                          partial=(len(results) < len(todo)))
        print(f"wrote {out_json}\nwrote {out_md}", file=sys.stderr)


if __name__ == "__main__":
    main()
