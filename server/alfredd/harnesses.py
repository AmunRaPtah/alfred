import os

# Alfred protocol v0: harness registry has exactly one entry.
_BASE = [
    {"id": "alfred", "name": "Alfred", "command": "alfred",
     "supports_profiles": False, "profiles": [], "models": [],
     "default_model": None, "note": None},
]

# `alfred`'s command is an absolute launcher path, not a $PATH binary.
LAUNCHER_PATH = "/root/.local/bin/alfred-brain"


def get_harnesses() -> list:
    out = []
    for h in _BASE:
        h = dict(h)
        h.setdefault("available", os.access(LAUNCHER_PATH, os.X_OK))
        out.append(h)
    return out
