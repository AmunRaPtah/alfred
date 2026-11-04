"""Minimal tmux helpers.

Alfred's PROTOCOL.md drops helmd's /box/* remote-control surface entirely
(no system status, service control, Claude-history browsing, GPU-burst
control, or shell escape hatch over the API). What survives here is only
what alfredd/reaper.py needs to find and reap idle ax-<sid> tmux sessions:
`_run`, `tmux_sessions`, and `tmux_kill`.
"""
import subprocess


def _run(cmd, timeout=10):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.stdout.strip()
    except Exception:
        return ""


_TMUX_FMT = "#{session_name}\t#{session_windows}\t#{session_created}\t#{session_attached}"


def tmux_sessions() -> list:
    out = _run(["tmux", "list-sessions", "-F", _TMUX_FMT])
    sessions = []
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) < 4:
            continue
        name, windows, created, attached = parts[:4]
        sessions.append({
            "name": name,
            "windows": int(windows) if windows.isdigit() else 0,
            "created": float(created) if created.replace(".", "").isdigit() else None,
            "attached": attached not in ("0", ""),
            "is_helm": name.startswith("ax-"),
        })
    sessions.sort(key=lambda s: (not s["attached"], s["name"]))
    return sessions


def tmux_kill(name: str) -> bool:
    r = subprocess.run(["tmux", "kill-session", "-t", name], capture_output=True)
    return r.returncode == 0
