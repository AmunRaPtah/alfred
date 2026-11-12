"""Alfred eval, "hard" suite: long-horizon multi-step tasks meant to separate
frontier models from small local ones (the 20 core tasks are saturated).

Same task format as tasks.py; every task here registers with suite="hard".
All fixtures are generated deterministically (fixed seeds), all graders are
deterministic and offline. Graders that need hidden tests write them to a
private temp dir outside the scratch dir and run them with PYTHONPATH set to
the scratch dir, so the agent never sees them.

Imported at the bottom of tasks.py; do not import tasks.py's TASKS-count
assert from here.
"""
import csv
import io
import json
import math
import os
import random
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import textwrap
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal, ROUND_HALF_UP

from tasks import task, _read, _sha  # noqa: F401


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------

def _write_tree(dir, files):
    for rel, content in files.items():
        p = os.path.join(dir, rel)
        os.makedirs(os.path.dirname(p) or dir, exist_ok=True)
        with open(p, "w") as f:
            f.write(textwrap.dedent(content).lstrip("\n") if isinstance(content, str) else content)


def _write_raw(dir, rel, content):
    p = os.path.join(dir, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w") as f:
        f.write(content)


_HARNESS = '''
import os, sys, subprocess, json, importlib
_tests = []
def t(fn):
    _tests.append(fn)
    return fn
def _main():
    fails = []
    for fn in _tests:
        try:
            fn()
        except BaseException as e:
            fails.append(f"{fn.__name__}: {type(e).__name__}: {e}"[:300])
    if fails:
        print(f"{len(fails)}/{len(_tests)} hidden tests failed:")
        for f in fails:
            print(" -", f)
        sys.exit(1)
    print(f"HIDDEN_OK {len(_tests)}")
'''


def _run_hidden(dir, body, timeout=180):
    """Run hidden test code (using the @t harness) against the scratch dir."""
    tmp = tempfile.mkdtemp(prefix="alfred-hidden-")
    path = os.path.join(tmp, "hidden_check.py")
    with open(path, "w") as f:
        f.write(_HARNESS + "\nSCRATCH = " + repr(dir) + "\n" + textwrap.dedent(body) + "\n_main()\n")
    env = dict(os.environ)
    env["PYTHONPATH"] = dir
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    try:
        r = subprocess.run([sys.executable, path], cwd=dir, env=env,
                           capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        shutil.rmtree(tmp, ignore_errors=True)
        return False, "hidden tests timed out"
    shutil.rmtree(tmp, ignore_errors=True)
    out = (r.stdout + r.stderr).strip()
    if r.returncode == 0 and "HIDDEN_OK" in r.stdout:
        return True, out.splitlines()[-1]
    return False, out[-700:]


def _load_json(dir, name):
    raw = _read(dir, name)
    if raw is None:
        return None, f"{name} missing"
    try:
        return json.loads(raw), None
    except Exception as e:
        return None, f"{name} is not valid JSON: {e}"


def _close(a, b, rel=5e-3, abs_=1e-9):
    try:
        a = float(a)
    except (TypeError, ValueError):
        return False
    return abs(a - b) <= max(abs_, rel * abs(b))


# ==========================================================================
# 1. hard_code: ledger package with three interacting bugs
# ==========================================================================

_LEDGER_RATES = {"EUR": 0.92, "GBP": 0.79, "CAD": 1.37}


def _ledger_rows(seed, n):
    rng = random.Random(seed)
    cats = ["meals", "office", "software", "travel"]
    curs = ["USD", "USD", "EUR", "GBP", "CAD"]
    rows = []
    specials = ["19.99", "0.29", "4.35", "1,204.57", "(45.10)", "0.57", "(0.29)", "2,310.10"]
    for i in range(n):
        if i < len(specials) and seed % 2 == 1:
            amt = specials[i]
        elif i + len(specials) >= n and seed % 2 == 0:
            amt = specials[n - 1 - i]
        else:
            cents = rng.randint(50, 250000)
            s = f"{cents // 100:,}.{cents % 100:02d}"
            amt = f"({s})" if rng.random() < 0.08 else s
        rows.append({"date": f"2026-{9 + seed % 2:02d}-{rng.randint(1, 28):02d}",
                     "category": rng.choice(cats), "currency": rng.choice(curs), "amount": amt})
    return rows


def _ledger_cents(s):
    s = s.strip().replace(",", "")
    neg = s.startswith("(") and s.endswith(")")
    if neg:
        s = s[1:-1]
    v = int((Decimal(s) * 100).to_integral_value())
    return -v if neg else v


def _ledger_usd(cents, cur, rates):
    if cur == "USD":
        return cents
    q = (Decimal(cents) / Decimal(str(rates[cur]))).quantize(Decimal(1), rounding=ROUND_HALF_UP)
    return int(q)


def _ledger_fmt(c):
    sign = "-" if c < 0 else ""
    c = abs(c)
    return f"{sign}{c // 100:,}.{c % 100:02d}"


def _ledger_render(month, rows, rates):
    tot = {}
    for r in rows:
        tot[r["category"]] = tot.get(r["category"], 0) + _ledger_usd(_ledger_cents(r["amount"]), r["currency"], rates)
    lines = [f"== {month} =="]
    for c in sorted(tot):
        lines.append(f"{c:<12}{_ledger_fmt(tot[c]):>12}")
    lines.append(f"{'TOTAL':<12}{_ledger_fmt(sum(tot.values())):>12}")
    return "\n".join(lines)


def _csv_text(rows, fields):
    buf = io.StringIO()
    w = csv.DictWriter(buf, fieldnames=fields, lineterminator="\n")
    w.writeheader()
    w.writerows(rows)
    return buf.getvalue()


@task("hard_ledger_bugs", "hard_code", timeout=900, suite="hard")
class HardLedgerBugs:
    def setup(dir):
        sep, octo = _ledger_rows(1, 40), _ledger_rows(2, 45)
        _write_tree(dir, {
            "README.md": """
                # ledger

                Tiny expense-report package. Monthly report:

                    python3 -m ledger.cli examples/rates.json examples/2026-09.csv examples/2026-10.csv

                Tests: `python3 -m pytest -q tests`. Behaviour is specified in SPEC.md.
                """,
            "SPEC.md": """
                # ledger spec

                * Amount strings: optional thousands separators (`1,234.50`), at most two
                  decimals, negative amounts (refunds) written in accounting style
                  `(12.00)`. `money.to_cents` must return the exact integer number of cents.
                * `examples/rates.json` (and any rates dict) maps a currency code to the
                  number of units of that currency that one US dollar buys
                  (e.g. `"EUR": 0.92` means 1 USD = 0.92 EUR).
                * `fx.to_usd_cents(cents, currency, rates)` converts an amount in that
                  currency's cents to US cents, rounded to the nearest cent.
                * `report.summarise(rows, rates)` returns a new dict mapping category to
                  total US cents for exactly the rows passed in.
                * `report.render(month, totals)` formats one month's block; the CLI prints
                  one block per CSV, separated by a blank line.
                """,
            "ledger/__init__.py": '"""Expense ledger."""\n',
            "ledger/money.py": '''
                """Money helpers. Amounts are handled as integer cents internally."""


                def to_cents(text):
                    """Parse an amount string like '1,234.50' or '(12.00)' into int cents."""
                    s = text.strip().replace(",", "")
                    neg = False
                    if s.startswith("(") and s.endswith(")"):
                        neg = True
                        s = s[1:-1]
                    value = int(float(s) * 100)
                    return -value if neg else value


                def fmt(cents):
                    sign = "-" if cents < 0 else ""
                    cents = abs(cents)
                    return f"{sign}{cents // 100:,}.{cents % 100:02d}"
                ''',
            "ledger/fx.py": '''
                """Currency conversion. See SPEC.md for the meaning of the rates table."""
                import json


                def load_rates(path):
                    with open(path) as f:
                        return json.load(f)


                def to_usd_cents(cents, currency, rates):
                    if currency == "USD":
                        return cents
                    rate = rates[currency]
                    return round(cents * rate)
                ''',
            "ledger/report.py": '''
                from .fx import to_usd_cents
                from .money import fmt, to_cents


                def summarise(rows, rates, totals={}):
                    for r in rows:
                        usd = to_usd_cents(to_cents(r["amount"]), r["currency"], rates)
                        totals[r["category"]] = totals.get(r["category"], 0) + usd
                    return totals


                def render(month, totals):
                    lines = [f"== {month} =="]
                    for cat in sorted(totals):
                        lines.append(f"{cat:<12}{fmt(totals[cat]):>12}")
                    lines.append(f"{'TOTAL':<12}{fmt(sum(totals.values())):>12}")
                    return "\\n".join(lines)
                ''',
            "ledger/cli.py": '''
                import csv
                import os
                import sys

                from .fx import load_rates
                from .report import render, summarise


                def read_rows(path):
                    with open(path, newline="") as f:
                        return list(csv.DictReader(f))


                def main(argv=None):
                    argv = sys.argv[1:] if argv is None else argv
                    rates_path, *csvs = argv
                    rates = load_rates(rates_path)
                    blocks = []
                    for p in csvs:
                        month = os.path.splitext(os.path.basename(p))[0]
                        blocks.append(render(month, summarise(read_rows(p), rates)))
                    print("\\n\\n".join(blocks))


                if __name__ == "__main__":
                    main()
                ''',
            "tests/test_ledger.py": '''
                import unittest

                from ledger.fx import to_usd_cents
                from ledger.money import fmt, to_cents
                from ledger.report import summarise


                class LedgerTests(unittest.TestCase):
                    def test_to_cents(self):
                        self.assertEqual(to_cents("10.00"), 1000)
                        self.assertEqual(to_cents("1,234.00"), 123400)
                        self.assertEqual(to_cents("(5.50)"), -550)

                    def test_fmt(self):
                        self.assertEqual(fmt(123456), "1,234.56")
                        self.assertEqual(fmt(-5), "-0.05")

                    def test_usd_passthrough(self):
                        self.assertEqual(to_usd_cents(500, "USD", {}), 500)

                    def test_summarise(self):
                        rows = [{"category": "a", "currency": "USD", "amount": "1.00"},
                                {"category": "a", "currency": "USD", "amount": "2.50"}]
                        self.assertEqual(summarise(rows, {})["a"], 350)


                if __name__ == "__main__":
                    unittest.main()
                ''',
        })
        _write_raw(dir, "examples/rates.json", json.dumps(_LEDGER_RATES, indent=2) + "\n")
        f = ["date", "category", "currency", "amount"]
        _write_raw(dir, "examples/2026-09.csv", _csv_text(sep, f))
        _write_raw(dir, "examples/2026-10.csv", _csv_text(octo, f))
        exp = _ledger_render("2026-09", sep, _LEDGER_RATES) + "\n\n" + _ledger_render("2026-10", octo, _LEDGER_RATES) + "\n"
        _write_raw(dir, "examples/expected_report.txt", exp)

    def prompt(dir):
        return (
            "Our expense report is wrong. Running `python3 -m ledger.cli examples/rates.json "
            "examples/2026-09.csv examples/2026-10.csv` does not match examples/expected_report.txt, "
            "which finance checked by hand. The unit tests in tests/ all pass, so they're clearly not "
            "catching it. Please find and fix whatever is wrong in the ledger package so it behaves "
            "as SPEC.md describes and the command's output matches the expected report exactly. "
            "Keep the public function names and parameters as they are, and don't edit anything "
            "in examples/."
        )

    def check(dir, text):
        exp = _ledger_render("2026-09", _ledger_rows(1, 40), _LEDGER_RATES) + "\n\n" + \
            _ledger_render("2026-10", _ledger_rows(2, 45), _LEDGER_RATES) + "\n"
        if _read(dir, "examples/expected_report.txt") != exp:
            return False, "examples/expected_report.txt was modified"
        hid_rows = _ledger_rows(5, 30)
        hid_rows2 = _ledger_rows(6, 25)
        hid_rates = {"EUR": 0.91, "GBP": 0.81, "CAD": 1.41}
        want = _ledger_render("x1", hid_rows, hid_rates) + "\n\n" + _ledger_render("x2", hid_rows2, hid_rates)
        body = f'''
            import csv, tempfile
            EXP = {exp!r}
            WANT = {want!r}
            ROWS1 = {hid_rows!r}
            ROWS2 = {hid_rows2!r}
            RATES = {hid_rates!r}

            @t
            def cli_matches_expected_report():
                r = subprocess.run([sys.executable, "-m", "ledger.cli", "examples/rates.json",
                                    "examples/2026-09.csv", "examples/2026-10.csv"],
                                   cwd=SCRATCH, capture_output=True, text=True, timeout=30)
                assert r.stdout == EXP, ("cli output differs", r.stdout[:300], r.stderr[-300:])

            @t
            def cli_hidden_months():
                d = tempfile.mkdtemp()
                for name, rows in (("x1", ROWS1), ("x2", ROWS2)):
                    with open(os.path.join(d, name + ".csv"), "w", newline="") as f:
                        w = csv.DictWriter(f, fieldnames=["date", "category", "currency", "amount"])
                        w.writeheader(); w.writerows(rows)
                with open(os.path.join(d, "r.json"), "w") as f:
                    json.dump(RATES, f)
                r = subprocess.run([sys.executable, "-m", "ledger.cli", os.path.join(d, "r.json"),
                                    os.path.join(d, "x1.csv"), os.path.join(d, "x2.csv")],
                                   cwd=SCRATCH, capture_output=True, text=True, timeout=30)
                assert r.stdout.strip() == WANT, ("hidden cli output differs", r.stdout[:200])

            @t
            def to_cents_exact():
                from ledger.money import to_cents
                for s, v in [("19.99", 1999), ("0.29", 29), ("4.35", 435), ("(0.29)", -29),
                             ("1,204.57", 120457), ("(2,310.10)", -231010), ("0.07", 7), ("1.15", 115)]:
                    assert to_cents(s) == v, (s, to_cents(s), v)

            @t
            def fx_direction():
                from ledger.fx import to_usd_cents
                assert to_usd_cents(9200, "EUR", {{"EUR": 0.92}}) == 10000
                assert to_usd_cents(137, "CAD", {{"CAD": 1.37}}) == 100
                assert to_usd_cents(1000, "GBP", {{"GBP": 0.79}}) == 1266
                assert to_usd_cents(-1000, "GBP", {{"GBP": 0.79}}) == -1266

            @t
            def summarise_is_stateless():
                from ledger.report import summarise
                rows = [{{"category": "a", "currency": "USD", "amount": "1.00"}}]
                summarise(rows, {{}})
                second = summarise(rows, {{}})
                assert second == {{"a": 100}}, second
                other = summarise([{{"category": "b", "currency": "USD", "amount": "2.00"}}], {{}})
                assert other == {{"b": 200}}, other

            @t
            def visible_tests_still_pass():
                r = subprocess.run([sys.executable, "-m", "pytest", "-q", "-p", "no:cacheprovider", "tests"],
                                   cwd=SCRATCH, capture_output=True, text=True, timeout=120)
                assert r.returncode == 0, r.stdout[-300:]
        '''
        ok, why = _run_hidden(dir, body)
        return ok, why


# ==========================================================================
# 2. hard_code: thread a new option through config, core and output
# ==========================================================================

def _wordstat_text():
    rng = random.Random(77)
    vocab = ["a", "I", "an", "to", "of", "the", "and", "is", "it's", "don't", "Data", "data",
             "model", "Model", "pipeline", "cat", "dog", "run", "running", "quick", "brown",
             "fox", "jumps", "over", "lazy", "eval", "Alfred", "alfred", "be", "we", "us",
             "kinase", "receptor", "dose", "AUC", "go", "no", "yes", "maybe", "always"]
    weights = [9, 6, 5, 8, 8, 12, 9, 6, 3, 3, 4, 4, 5, 2, 3, 2, 2, 3, 2, 2, 2, 2, 2, 2, 2,
               2, 2, 2, 4, 4, 3, 1, 1, 2, 1, 3, 3, 2, 1, 1]
    lines = []
    for _ in range(140):
        n = rng.randint(6, 18)
        words = rng.choices(vocab, weights=weights, k=n)
        punct = rng.choice([".", "!", "?", ",", ";", " --"])
        lines.append(" ".join(words) + punct)
    return "\n".join(lines) + "\n"


@task("hard_wordstat_feature", "hard_code", timeout=900, suite="hard")
class HardWordstatFeature:
    def setup(dir):
        _write_tree(dir, {
            "README.md": """
                # wordstat

                    python3 -m wordstat.cli [--top N] [--format text|json] [--case-sensitive]
                                            [--config PATH] FILE

                Settings come from built-in defaults, then the `[wordstat]` section of
                `wordstat.ini` in the current directory (or `--config PATH`), then
                command-line flags, later sources winning.
                """,
            "wordstat/__init__.py": "",
            "wordstat/config.py": '''
                """Settings: defaults < ini file [wordstat] section < command-line flags."""
                import configparser
                import os
                from dataclasses import dataclass

                DEFAULTS = {"top": 10, "format": "text", "ignore_case": True}


                @dataclass
                class Config:
                    top: int = 10
                    format: str = "text"
                    ignore_case: bool = True


                def load(path=None, overrides=None):
                    values = dict(DEFAULTS)
                    if path and os.path.exists(path):
                        cp = configparser.ConfigParser()
                        cp.read(path)
                        if cp.has_section("wordstat"):
                            sec = cp["wordstat"]
                            if "top" in sec:
                                values["top"] = sec.getint("top")
                            if "format" in sec:
                                values["format"] = sec.get("format")
                            if "ignore_case" in sec:
                                values["ignore_case"] = sec.getboolean("ignore_case")
                    for k, v in (overrides or {}).items():
                        if v is not None:
                            values[k] = v
                    if values["format"] not in ("text", "json"):
                        raise ValueError(f"unknown format {values['format']!r}")
                    if values["top"] < 1:
                        raise ValueError("top must be >= 1")
                    return Config(**values)
                ''',
            "wordstat/core.py": '''
                import re
                from collections import Counter

                WORD = re.compile(r"[A-Za-z']+")


                def tokenize(text, ignore_case=True):
                    words = WORD.findall(text)
                    return [w.lower() for w in words] if ignore_case else words


                def count(text, cfg):
                    words = tokenize(text, cfg.ignore_case)
                    c = Counter(words)
                    ranked = sorted(c.items(), key=lambda kv: (-kv[1], kv[0]))
                    return {"total_words": len(words), "unique_words": len(c),
                            "top": ranked[: cfg.top]}
                ''',
            "wordstat/output.py": '''
                import json


                def render(stats, cfg):
                    if cfg.format == "json":
                        return json.dumps({
                            "settings": {"top": cfg.top, "ignore_case": cfg.ignore_case},
                            "total_words": stats["total_words"],
                            "unique_words": stats["unique_words"],
                            "top": [{"word": w, "count": n} for w, n in stats["top"]],
                        }, indent=2)
                    lines = [f"# wordstat top={cfg.top} ignore_case={cfg.ignore_case}",
                             f"total_words: {stats['total_words']}",
                             f"unique_words: {stats['unique_words']}"]
                    for w, n in stats["top"]:
                        lines.append(f"{n:>6} {w}")
                    return "\\n".join(lines)
                ''',
            "wordstat/cli.py": '''
                import argparse
                import sys

                from . import config, core, output


                def main(argv=None):
                    ap = argparse.ArgumentParser(prog="wordstat")
                    ap.add_argument("file")
                    ap.add_argument("--top", type=int)
                    ap.add_argument("--format", choices=["text", "json"])
                    ap.add_argument("--case-sensitive", action="store_true")
                    ap.add_argument("--config", default="wordstat.ini")
                    a = ap.parse_args(argv)
                    try:
                        cfg = config.load(a.config, {"top": a.top, "format": a.format,
                                                     "ignore_case": False if a.case_sensitive else None})
                    except ValueError as e:
                        ap.error(str(e))
                    with open(a.file) as f:
                        text = f.read()
                    print(output.render(core.count(text, cfg), cfg))
                    return 0


                if __name__ == "__main__":
                    sys.exit(main())
                ''',
            "tests/test_wordstat.py": '''
                import json
                import subprocess
                import sys
                import unittest

                from wordstat import config, core


                class WordstatTests(unittest.TestCase):
                    def test_defaults(self):
                        cfg = config.load(None)
                        self.assertEqual(cfg.top, 10)
                        self.assertTrue(cfg.ignore_case)

                    def test_count(self):
                        cfg = config.load(None, {"top": 2})
                        s = core.count("b a b c b a", cfg)
                        self.assertEqual(s["top"], [("b", 3), ("a", 2)])
                        self.assertEqual(s["total_words"], 6)

                    def test_cli_json(self):
                        r = subprocess.run([sys.executable, "-m", "wordstat.cli", "--format", "json",
                                            "--top", "3", "sample.txt"], capture_output=True, text=True)
                        self.assertEqual(r.returncode, 0, r.stderr)
                        self.assertEqual(json.loads(r.stdout)["settings"]["top"], 3)


                if __name__ == "__main__":
                    unittest.main()
                ''',
        })
        _write_raw(dir, "sample.txt", _wordstat_text())

    def prompt(dir):
        return (
            "Please add a minimum word length setting to wordstat. Words shorter than N "
            "characters should be ignored completely (they don't count toward total_words, "
            "unique_words or the top list). It needs to be settable as `--min-length N` on the "
            "command line and as `min_length` in the [wordstat] section of the ini file, default 1, "
            "with the same precedence the other settings have. The active value should appear in "
            "the output the same way the other settings do, in both text and JSON format. Values "
            "below 1 are a user error: the CLI should exit non-zero instead of running. Don't "
            "break anything that works today, and add tests for the new option under tests/."
        )

    def check(dir, text):
        body = r'''
            import re, tempfile
            from collections import Counter
            TEXT = open(os.path.join(SCRATCH, "sample.txt")).read()

            def expect(n, top=10, ignore_case=True):
                words = re.findall(r"[A-Za-z']+", TEXT)
                if ignore_case:
                    words = [w.lower() for w in words]
                words = [w for w in words if len(w) >= n]
                c = Counter(words)
                ranked = sorted(c.items(), key=lambda kv: (-kv[1], kv[0]))[:top]
                return len(words), len(c), ranked

            def run(args, cwd=None, ini=None):
                d = cwd or tempfile.mkdtemp()
                if ini is not None:
                    with open(os.path.join(d, "wordstat.ini"), "w") as f:
                        f.write(ini)
                return subprocess.run([sys.executable, "-m", "wordstat.cli"] + args +
                                      [os.path.join(SCRATCH, "sample.txt")], cwd=d,
                                      capture_output=True, text=True, timeout=30,
                                      env=dict(os.environ, PYTHONPATH=SCRATCH))

            def check_text(r, n, top=10, ignore_case=True):
                assert r.returncode == 0, r.stderr[-300:]
                lines = r.stdout.strip().splitlines()
                assert re.search(r"\bmin_length=%d\b" % n, lines[0]), ("header", lines[0])
                tw, uw, ranked = expect(n, top, ignore_case)
                rest = [l for l in lines[1:] if not re.match(r"^\s*#?\s*min_length", l)]
                want = [f"total_words: {tw}", f"unique_words: {uw}"] + [f"{c:>6} {w}" for w, c in ranked]
                assert rest == want, ("body", rest[:4], want[:4])

            def check_json(r, n, top=10):
                assert r.returncode == 0, r.stderr[-300:]
                o = json.loads(r.stdout)
                assert o["settings"]["min_length"] == n, o["settings"]
                tw, uw, ranked = expect(n, top)
                assert o["total_words"] == tw and o["unique_words"] == uw, (o["total_words"], tw)
                assert [(x["word"], x["count"]) for x in o["top"]] == ranked

            @t
            def default_is_one_and_unchanged():
                check_text(run([]), 1)
                check_json(run(["--format", "json"]), 1)

            @t
            def cli_flag_text():
                check_text(run(["--min-length", "4"]), 4)

            @t
            def cli_flag_json_with_top():
                check_json(run(["--min-length", "3", "--format", "json", "--top", "5"]), 3, top=5)

            @t
            def ini_value_applies():
                check_text(run([], ini="[wordstat]\nmin_length = 5\n"), 5)

            @t
            def cli_beats_ini():
                check_json(run(["--min-length", "2", "--format", "json"], ini="[wordstat]\nmin_length = 6\n"), 2)

            @t
            def ini_with_other_settings():
                check_text(run(["--case-sensitive"], ini="[wordstat]\nmin_length = 4\ntop = 7\n"), 4, top=7, ignore_case=False)

            @t
            def zero_rejected_cli():
                r = run(["--min-length", "0"])
                assert r.returncode != 0, "accepted --min-length 0"

            @t
            def negative_rejected_ini():
                r = run([], ini="[wordstat]\nmin_length = -2\n")
                assert r.returncode != 0, "accepted min_length=-2 from ini"

            @t
            def config_api():
                from wordstat import config
                assert config.load(None).min_length == 1
                assert config.load(None, {"min_length": 3}).min_length == 3

            @t
            def visible_tests_pass_and_cover_option():
                r = subprocess.run([sys.executable, "-m", "pytest", "-q", "-p", "no:cacheprovider", "tests"],
                                   cwd=SCRATCH, capture_output=True, text=True, timeout=120)
                assert r.returncode == 0, r.stdout[-300:]
                src = "".join(open(os.path.join(SCRATCH, "tests", f)).read()
                              for f in os.listdir(os.path.join(SCRATCH, "tests")) if f.endswith(".py"))
                assert "min_length" in src or "min-length" in src, "no tests for the new option"
        '''
        return _run_hidden(dir, body)


# ==========================================================================
# 3. hard_debug: syncd failed overnight; root causes in code, config is
#    regenerated by deploy so it must not be edited
# ==========================================================================

_SYNC_LEVELS = {"debug": 0, "info": 1, "warning": 2, "error": 3, "critical": 4}


def _sync_events(seed, day, offset_min):
    """Events spread around one local day; returns (jsonl_text, events)."""
    rng = random.Random(seed)
    d0 = datetime.strptime(day, "%Y-%m-%d").replace(tzinfo=timezone.utc)
    start_utc = d0 - timedelta(minutes=offset_min)
    lo = start_utc - timedelta(hours=10)
    span = int(timedelta(hours=44).total_seconds())
    evs = []
    for i in range(420):
        ts = lo + timedelta(seconds=rng.randint(0, span))
        lvl = rng.choices(list(_SYNC_LEVELS), weights=[30, 40, 15, 10, 5])[0]
        evs.append({"ts": ts, "level": lvl})
    # boundary events: exactly at window start (in) and one second past the end (out)
    evs.append({"ts": start_utc, "level": "error"})
    evs.append({"ts": start_utc + timedelta(days=1), "level": "critical"})
    evs.sort(key=lambda e: e["ts"])
    out = []
    for i, e in enumerate(evs):
        out.append(json.dumps({"id": f"ev-{seed}-{i:04d}", "ts": e["ts"].strftime("%Y-%m-%dT%H:%M:%SZ"),
                               "level": e["level"], "msg": f"event {i}"}))
        if i in (57, 203, 377):
            out.append("")
    return "\n".join(out) + "\n\n", evs


def _sync_expected(evs, day, offset_min, min_sev):
    d0 = datetime.strptime(day, "%Y-%m-%d").replace(tzinfo=timezone.utc)
    start = d0 - timedelta(minutes=offset_min)
    end = start + timedelta(days=1) - timedelta(seconds=1)
    return sum(1 for e in evs if start <= e["ts"] <= end and _SYNC_LEVELS[e["level"]] >= min_sev)


def _sync_ini(day, tz, sev):
    return (f"# generated by deploy-tool 7.3 -- do not edit by hand\n"
            f"[source]\npath = data/events-{day}.jsonl\n\n"
            f"[window]\nstart = {day} 00:00:00\nend = {day} 23:59:59\ntz_offset = {tz}\n\n"
            f"[filter]\nmin_severity = {sev}\n\n"
            f"[metrics]\nendpoint = 127.0.0.1:9109\n")


_SYNC_MAIN_DAY = "2026-11-04"


@task("hard_syncd_debug", "hard_debug", timeout=900, suite="hard")
class HardSyncdDebug:
    def setup(dir):
        data, _ = _sync_events(11, _SYNC_MAIN_DAY, 330)
        _write_raw(dir, f"data/events-{_SYNC_MAIN_DAY}.jsonl", data)
        _write_raw(dir, "config/syncd.ini", _sync_ini(_SYNC_MAIN_DAY, "+0530", "warning"))
        _write_tree(dir, {
            "run.sh": """
                #!/usr/bin/env bash
                set -euo pipefail
                cd "$(dirname "$0")"
                exec python3 syncd/main.py --config config/syncd.ini
                """,
            "syncd/main.py": '''
                #!/usr/bin/env python3
                """syncd: push one local day's events from the export to upstream.

                The upstream push is stubbed in this checkout; what matters is record
                selection, which has to match the upstream dashboard count.
                """
                import argparse
                import configparser
                import json
                import logging
                import os
                import sys
                from datetime import datetime, timedelta

                sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
                import metrics  # noqa: E402
                from levels import LEVELS  # noqa: E402
                from timeutil import fmt_offset, local_to_utc, parse_offset  # noqa: E402

                VERSION = "4.2.1"
                log = logging.getLogger("syncd")


                def read_config(path):
                    cp = configparser.ConfigParser()
                    if not cp.read(path):
                        raise SystemExit(f"config not found: {path}")
                    return cp


                def severity_threshold(cp):
                    raw = cp.get("filter", "min_severity", fallback="4")
                    try:
                        return int(raw)
                    except ValueError:
                        log.warning("min_severity %r not understood, using default 4", raw)
                        return 4


                def window(cp):
                    raw = cp.get("window", "tz_offset", fallback="+00:00")
                    try:
                        off = parse_offset(raw)
                    except ValueError:
                        log.warning("bad tz_offset %r, falling back to UTC", raw)
                        off = timedelta(0)
                    s, e = cp.get("window", "start"), cp.get("window", "end")
                    log.info("window %s -> %s (UTC%s)", s, e, fmt_offset(off))
                    return local_to_utc(s, off), local_to_utc(e, off)


                def load_events(path):
                    events = []
                    with open(path, encoding="utf-8") as f:
                        for line in f:
                            events.append(json.loads(line))
                    return events


                def select(events, start, end, min_sev):
                    out = []
                    for e in events:
                        ts = datetime.fromisoformat(e["ts"].replace("Z", "+00:00"))
                        if start <= ts <= end and LEVELS[e["level"]] >= min_sev:
                            out.append(e)
                    return out


                def main(argv=None):
                    ap = argparse.ArgumentParser()
                    ap.add_argument("--config", required=True)
                    args = ap.parse_args(argv)
                    logging.basicConfig(level=logging.INFO, stream=sys.stderr,
                                        format="%(asctime)s %(levelname)s %(message)s")
                    log.info("syncd %s starting, config=%s", VERSION, args.config)
                    cp = read_config(args.config)
                    min_sev = severity_threshold(cp)
                    log.info("filter min_severity=%d", min_sev)
                    start, end = window(cp)
                    metrics.init(cp)
                    path = cp.get("source", "path")
                    log.info("loading %s", path)
                    chosen = select(load_events(path), start, end, min_sev)
                    if not chosen:
                        log.error("no records in window, refusing to push an empty batch")
                        return 1
                    metrics.push(len(chosen))
                    print(f"synced {len(chosen)} records")
                    return 0


                if __name__ == "__main__":
                    sys.exit(main())
                ''',
            "syncd/timeutil.py": '''
                from datetime import datetime, timedelta, timezone


                def parse_offset(s):
                    """Parse a UTC offset such as '+05:30' or '-03:00' into a timedelta."""
                    s = s.strip()
                    sign = -1 if s.startswith("-") else 1
                    hh, mm = s.lstrip("+-").split(":")
                    return sign * timedelta(hours=int(hh), minutes=int(mm))


                def fmt_offset(off):
                    mins = int(off.total_seconds() // 60)
                    sign = "-" if mins < 0 else "+"
                    mins = abs(mins)
                    return f"{sign}{mins // 60:02d}:{mins % 60:02d}"


                def local_to_utc(text, offset):
                    naive = datetime.strptime(text, "%Y-%m-%d %H:%M:%S")
                    return (naive - offset).replace(tzinfo=timezone.utc)
                ''',
            "syncd/levels.py": '''
                """Severity levels used in the event export."""
                LEVELS = {"debug": 0, "info": 1, "warning": 2, "error": 3, "critical": 4}
                ''',
            "syncd/metrics.py": '''
                """Best-effort metrics push. Failures are logged upstream and never fatal.
                Stubbed out in this checkout."""


                def init(cp):
                    return None


                def push(n):
                    return None
                ''',
            "logs/syncd-2026-11-03.log": """
                2026-11-04 02:00:01,114 INFO syncd 4.1.9 starting, config=config/syncd.ini
                2026-11-04 02:00:01,115 INFO filter min_severity=2
                2026-11-04 02:00:01,115 INFO window 2026-11-03 00:00:00 -> 2026-11-03 23:59:59 (UTC+05:30)
                2026-11-04 02:00:01,131 WARNING metrics push to 127.0.0.1:9109 failed: [Errno 111] Connection refused (will retry)
                2026-11-04 02:00:01,132 INFO loading data/events-2026-11-03.jsonl
                synced 41 records
                """,
            "logs/syncd-2026-11-04.log": """
                2026-11-05 02:00:01,402 INFO syncd 4.2.1 starting, config=config/syncd.ini
                2026-11-05 02:00:01,402 WARNING min_severity 'warning' not understood, using default 4
                2026-11-05 02:00:01,403 INFO filter min_severity=4
                2026-11-05 02:00:01,403 WARNING bad tz_offset '+0530', falling back to UTC
                2026-11-05 02:00:01,403 INFO window 2026-11-04 00:00:00 -> 2026-11-04 23:59:59 (UTC+00:00)
                2026-11-05 02:00:01,419 WARNING metrics push to 127.0.0.1:9109 failed: [Errno 111] Connection refused (will retry)
                2026-11-05 02:00:01,420 INFO loading data/events-2026-11-04.jsonl
                Traceback (most recent call last):
                  File "/opt/syncd/syncd/main.py", line 97, in <module>
                    sys.exit(main())
                  File "/opt/syncd/syncd/main.py", line 85, in main
                    chosen = select(load_events(path), start, end, min_sev)
                  File "/opt/syncd/syncd/main.py", line 62, in load_events
                    events.append(json.loads(line))
                  File "/usr/lib/python3.12/json/__init__.py", line 346, in loads
                    return _default_decoder.decode(s)
                json.decoder.JSONDecodeError: Expecting value: line 1 column 1 (char 0)
                2026-11-05 02:00:02,001 ERROR supervisor: syncd exited with status 1
                """,
            "DEPLOY.md": """
                # Deploy notes

                `config/syncd.ini` is rendered by deploy-tool on every deploy and is
                overwritten each time; hand edits there do not survive. deploy-tool 7.x
                writes offsets as `+HHMM` and severities by name. Hosts that have not been
                redeployed since 6.x still carry configs with `+HH:MM` offsets and numeric
                severities. The event export under `data/` is produced upstream.
                """,
        })
        os.chmod(os.path.join(dir, "run.sh"), 0o755)

    def _expected_main():
        _, evs = _sync_events(11, _SYNC_MAIN_DAY, 330)
        return _sync_expected(evs, _SYNC_MAIN_DAY, 330, 2)

    def prompt(dir):
        n = HardSyncdDebug._expected_main()
        return (
            "syncd failed in last night's run (logs are in logs/). Please get it working again: "
            f"`./run.sh` must exit 0 and print `synced {n} records` for the 2026-11-04 window, "
            "which is what the upstream dashboard shows for that day. Fix it in the code. "
            "Don't touch config/syncd.ini, the data files or run.sh: see DEPLOY.md for why, and "
            "whatever you change has to keep working on every host we run."
        )

    def check(dir, text):
        n = HardSyncdDebug._expected_main()
        cfg = _read(dir, "config/syncd.ini")
        if cfg != _sync_ini(_SYNC_MAIN_DAY, "+0530", "warning"):
            return False, "config/syncd.ini was modified"
        data, _ = _sync_events(11, _SYNC_MAIN_DAY, 330)
        if _read(dir, f"data/events-{_SYNC_MAIN_DAY}.jsonl") != data:
            return False, "data file was modified"
        runsh = _read(dir, "run.sh") or ""
        if "exec python3 syncd/main.py --config config/syncd.ini" not in runsh:
            return False, "run.sh was modified"

        def run(d):
            try:
                return subprocess.run(["bash", "run.sh"], cwd=d, capture_output=True, text=True, timeout=60)
            except Exception as e:
                return e

        r = run(dir)
        if isinstance(r, Exception):
            return False, f"run.sh failed to run: {r}"
        if r.returncode != 0 or f"synced {n} records" not in r.stdout:
            return False, f"main run: rc={r.returncode} out={r.stdout.strip()[-120:]!r} err={r.stderr.strip()[-200:]!r}"
        # Other hosts: new-format and old-format configs, different days/offsets.
        variants = [("2026-11-05", 21, "-0330", -210, "error", 3),
                    ("2026-11-06", 31, "+01:00", 60, "3", 3),
                    ("2026-11-07", 41, "+00:00", 0, "2", 2),
                    ("2026-11-08", 51, "+0900", 540, "critical", 4)]
        for day, seed, tz, off, sev, sevn in variants:
            tmp = tempfile.mkdtemp(prefix="alfred-syncd-")
            try:
                d = os.path.join(tmp, "s")
                shutil.copytree(dir, d, ignore=shutil.ignore_patterns("__pycache__"))
                data_v, evs = _sync_events(seed, day, off)
                _write_raw(d, f"data/events-{day}.jsonl", data_v)
                _write_raw(d, "config/syncd.ini", _sync_ini(day, tz, sev))
                want = _sync_expected(evs, day, off, sevn)
                r = run(d)
                if isinstance(r, Exception) or r.returncode != 0 or f"synced {want} records" not in r.stdout:
                    got = r if isinstance(r, Exception) else (r.returncode, r.stdout.strip()[-80:], r.stderr.strip()[-160:])
                    return False, f"other-host config tz={tz} sev={sev}: expected 'synced {want} records', got {got!r}"
            finally:
                shutil.rmtree(tmp, ignore_errors=True)
        return True, f"run.sh prints synced {n} records; 4 other host configs also correct"


# ==========================================================================
# 4. hard_data: messy multi-site dispensing export
# ==========================================================================

_DISP_DRUGS = {
    "amoxicillin": [250, 500, 500, 1000],
    "metformin": [500, 850, 1000],
    "paracetamol": [500, 1000, 1000],
    "ibuprofen": [200, 400],
    "levothyroxine": [0.05, 0.075, 0.1],
    "cholecalciferol": [0.025, 0.05],
}
_MISSING = ["", "NA", "n/a", "N/A", "-"]


def _disp_fmt_num(x):
    s = f"{x:.6f}".rstrip("0").rstrip(".")
    return s


def _disp_generate():
    rng = random.Random(2026)
    months = [1, 2, 3, 4, 5, 6]
    mweights = [14, 17, 22, 16, 18, 13]
    rows = []      # raw output rows (dicts of strings)
    truth = []     # (order_key, patient_key, drug, mg or None, month)
    for i in range(1, 541):
        site = rng.choice("ABC")
        drug = rng.choice(list(_DISP_DRUGS))
        mg = rng.choice(_DISP_DRUGS[drug])
        m = rng.choices(months, weights=mweights)[0]
        dd = rng.randint(1, 28)
        pid = rng.randint(1, 160)
        oid = f"ORD-{i:05d}"
        missing = rng.random() < 0.06
        if site == "C":
            dose_s = _disp_fmt_num(mg / 1000.0)
            unit = "mg"
        else:
            r = rng.random()
            if mg < 1:  # microgram drugs
                if r < 0.5:
                    dose_s, unit = _disp_fmt_num(mg * 1000), rng.choice(["mcg", "µg", "ug"])
                else:
                    dose_s, unit = _disp_fmt_num(mg), rng.choice(["mg", "MG"])
            else:
                if r < 0.25 and mg >= 500:
                    dose_s, unit = _disp_fmt_num(mg / 1000.0), "g"
                else:
                    dose_s, unit = _disp_fmt_num(mg), rng.choice(["mg", "mg", "MG"])
        if missing:
            dose_s = rng.choice(_MISSING)
        dstr = f"{dd:02d}/{m:02d}/2026" if site == "B" else f"2026-{m:02d}-{dd:02d}"
        name = rng.choice([drug, drug.capitalize(), drug.upper(), f" {drug}", f"{drug.capitalize()} "])
        pstr = rng.choice([f"P{pid:04d}", f"p{pid:04d}", f" P{pid:04d}"])
        rows.append({"order_id": oid, "patient_id": pstr, "drug": name, "dose": dose_s,
                     "unit": unit, "order_date": dstr, "site": site})
        truth.append((oid.lower(), f"p{pid:04d}", drug, None if missing else mg, f"2026-{m:02d}"))
    # re-exported duplicates, inserted after their original
    out = list(rows)
    n_dup = 0
    for _ in range(64):
        j = rng.randrange(len(rows))
        src = dict(rows[j])
        src["order_id"] = rng.choice([src["order_id"].lower(), f" {src['order_id']}", f"{src['order_id']} ",
                                      src["order_id"]])
        src["drug"] = rng.choice([src["drug"].strip().lower(), src["drug"].upper()])
        pos = out.index(rows[j]) + 1 + rng.randint(0, 40)
        out.insert(min(pos, len(out)), src)
        n_dup += 1
    return out, truth


def _disp_expected():
    raw, _ = _disp_generate()
    seen = set()
    dedup = []
    for r in raw:
        k = r["order_id"].strip().lower()
        if k in seen:
            continue
        seen.add(k)
        dedup.append(r)
    clean = []
    for r in dedup:
        d = r["dose"].strip()
        if d.lower() in ("", "na", "n/a", "-"):
            continue
        v = float(d)
        unit = r["unit"].strip().lower()
        if r["site"] == "C":
            mg = v * 1000
        elif unit == "g":
            mg = v * 1000
        elif unit in ("mcg", "µg", "ug"):
            mg = v / 1000
        else:
            mg = v
        ds = r["order_date"].strip()
        if "/" in ds:
            dd, mm, yy = ds.split("/")
            month = f"{yy}-{mm}"
        else:
            month = ds[:7]
        clean.append((r["patient_id"].strip().lower(), r["drug"].strip().lower(), mg, month))
    by = {}
    for _, drug, mg, _ in clean:
        by.setdefault(drug, []).append(mg)
    months = {}
    for *_, m in clean:
        months[m] = months.get(m, 0) + 1
    best = sorted(months.items(), key=lambda kv: (-kv[1], kv[0]))[0][0]
    return {
        "n_rows_raw": len(raw),
        "n_duplicates_removed": len(raw) - len(dedup),
        "n_missing_dose_removed": len(dedup) - len(clean),
        "n_clean": len(clean),
        "unique_patients": len({p for p, *_ in clean}),
        "by_drug": {d: {"orders": len(v), "total_mg": sum(v), "median_mg": statistics.median(v)}
                    for d, v in sorted(by.items())},
        "busiest_month": best,
    }


@task("hard_dispense_clean", "hard_data", timeout=900, suite="hard")
class HardDispenseClean:
    def setup(dir):
        raw, _ = _disp_generate()
        _write_raw(dir, "dispensing_export.csv",
                   _csv_text(raw, ["order_id", "patient_id", "drug", "dose", "unit", "order_date", "site"]))
        _write_tree(dir, {"DATA_NOTES.md": """
            # Dispensing export: notes from the data team

            * One file, concatenated from the three sites' dispensing systems (column `site`).
            * Re-exports: some orders were exported more than once. `order_id` identifies an
              order; IDs are case-insensitive and may carry stray whitespace. The same holds
              for `patient_id`.
            * Drug names are free text from each site: inconsistent case and stray spaces.
            * Units seen: mg (also `MG`), g, and micrograms written as mcg, µg or ug.
            * Missing doses appear as an empty cell or a placeholder such as NA, n/a, N/A or -.
            * Dates: sites A and C write ISO dates (YYYY-MM-DD). Site B writes DD/MM/YYYY.
            * Known export bug (ticket DX-311, not yet fixed): site C's system writes the dose
              value in grams, but its unit column is hard-coded to "mg". The numbers in the
              dose column for site C are grams.
            """})

    def prompt(dir):
        return (
            "dispensing_export.csv is our raw first-half-2026 dispensing export. Read DATA_NOTES.md "
            "first, then clean the data and write results.json with these keys:\n"
            "- n_rows_raw: data rows in the file (excluding the header)\n"
            "- n_duplicates_removed: rows dropped as repeat exports of an order already seen "
            "(keep the first occurrence in file order)\n"
            "- n_missing_dose_removed: after de-duplication, rows dropped because the dose is missing\n"
            "- n_clean: rows remaining\n"
            "- unique_patients: distinct patients among the remaining rows\n"
            "- by_drug: object keyed by drug name in lowercase, each value an object with "
            "\"orders\" (count), \"total_mg\" and \"median_mg\" (dose per order converted to mg)\n"
            "- busiest_month: the YYYY-MM with the most remaining orders (earliest month if tied)\n"
            "Numbers should be plain JSON numbers."
        )

    def check(dir, text):
        got, err = _load_json(dir, "results.json")
        if err:
            return False, err
        exp = _disp_expected()
        problems = []
        for k in ["n_rows_raw", "n_duplicates_removed", "n_missing_dose_removed", "n_clean", "unique_patients"]:
            if got.get(k) != exp[k]:
                problems.append(f"{k}={got.get(k)!r} want {exp[k]}")
        if got.get("busiest_month") != exp["busiest_month"]:
            problems.append(f"busiest_month={got.get('busiest_month')!r} want {exp['busiest_month']}")
        bd = got.get("by_drug")
        if not isinstance(bd, dict) or set(bd) != set(exp["by_drug"]):
            problems.append(f"by_drug keys {sorted(bd) if isinstance(bd, dict) else bd!r}")
        else:
            for d, e in exp["by_drug"].items():
                g = bd[d]
                if not isinstance(g, dict) or g.get("orders") != e["orders"] \
                        or not _close(g.get("total_mg"), e["total_mg"], rel=1e-4) \
                        or not _close(g.get("median_mg"), e["median_mg"], rel=1e-4):
                    problems.append(f"{d}: got {g} want {e}")
        if problems:
            return False, "; ".join(problems)[:600]
        return True, "all cleaned statistics match"


# ==========================================================================
# 5. hard_data: non-compartmental PK analysis across subjects
# ==========================================================================

_PK_NOMINAL = [0, 0.25, 0.5, 1, 1.5, 2, 3, 4, 6, 8, 12, 24, 36, 48]
_PK_LLOQ = 5.0
_PK_DOSE = 200.0


def _pk_sig3(x):
    if x <= 0:
        return 0.0
    return float(f"{x:.3g}")


def _pk_generate():
    rng = random.Random(4242)
    rows = []
    for s in range(1, 7):
        sid = f"S{s:02d}"
        ka = rng.uniform(0.7, 2.5)
        ke = rng.uniform(0.06, 0.22)
        V = rng.uniform(55, 120)
        seen_blq = False
        tmax_passed = False
        prev = 0
        for i, tn in enumerate(_PK_NOMINAL):
            if tn == 0:
                ta = 0.0
            elif tn <= 2:
                ta = round(tn + rng.uniform(0.0, 0.12), 2)
            else:
                ta = round(tn + rng.uniform(-0.3, 0.6), 2)
            if tn == 0:
                conc = "BLQ"
            else:
                c = 1000 * _PK_DOSE * ka / (V * (ka - ke)) * (math.exp(-ke * ta) - math.exp(-ka * ta))
                c *= math.exp(rng.gauss(0, 0.07))
                c = _pk_sig3(c)
                if c < prev:
                    tmax_passed = True
                prev = c
                if tmax_passed and (seen_blq or c < _PK_LLOQ):
                    seen_blq = True
                    conc = "BLQ"
                else:
                    conc = f"{c:g}"
            if sid == "S04" and tn == 8:
                conc = ""
            rows.append({"subject": sid, "nominal_time_h": f"{tn:g}", "actual_time_h": f"{ta:g}",
                         "conc_ng_per_mL": conc})
    return rows


def _pk_nca(rows, time_key="actual_time_h", log_down=True, n_lz=3):
    res = {}
    subs = sorted({r["subject"] for r in rows})
    for sid in subs:
        pts = []
        for r in rows:
            if r["subject"] != sid:
                continue
            c = r["conc_ng_per_mL"].strip()
            t = float(r[time_key])
            if c == "":
                continue
            if c.upper() == "BLQ":
                if not pts or all(p[1] == 0 for p in pts):
                    pts.append((t, 0.0))
                continue
            pts.append((t, float(c)))
        pts.sort()
        cmax = max(c for _, c in pts)
        tmax = next(t for t, c in pts if c == cmax)
        q = [(t, c) for t, c in pts if c > 0]
        last = q[-n_lz:]
        xs = [t for t, _ in last]
        ys = [math.log(c) for _, c in last]
        mx, my = sum(xs) / len(xs), sum(ys) / len(ys)
        slope = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sum((x - mx) ** 2 for x in xs)
        lz = -slope
        auc = 0.0
        for (t1, c1), (t2, c2) in zip(pts, pts[1:]):
            if log_down and c2 < c1 and c1 > 0 and c2 > 0:
                auc += (c1 - c2) * (t2 - t1) / math.log(c1 / c2)
            else:
                auc += (c1 + c2) / 2 * (t2 - t1)
        clast = q[-1][1]
        aucinf = auc + clast / lz
        res[sid] = {"cmax": cmax, "tmax": tmax, "lambda_z": lz, "half_life_h": math.log(2) / lz,
                    "auc_0_tlast": auc, "auc_0_inf": aucinf, "cl_f_L_per_h": _PK_DOSE * 1000 / aucinf}
    gm = math.exp(sum(math.log(v["auc_0_inf"]) for v in res.values()) / len(res))
    return {"subjects": res, "geomean_auc_0_inf": gm}


def _pk_compare(got, exp, rel=5e-3):
    if not isinstance(got, dict) or not isinstance(got.get("subjects"), dict):
        return ["missing 'subjects' object"]
    probs = []
    if set(got["subjects"]) != set(exp["subjects"]):
        return [f"subjects {sorted(got['subjects'])} want {sorted(exp['subjects'])}"]
    for sid, e in exp["subjects"].items():
        g = got["subjects"][sid]
        for k, v in e.items():
            if not isinstance(g, dict) or not _close(g.get(k), v, rel=rel if k != "tmax" else 1e-9):
                probs.append(f"{sid}.{k}={g.get(k) if isinstance(g, dict) else g!r} want {v:.6g}")
    if not _close(got.get("geomean_auc_0_inf"), exp["geomean_auc_0_inf"], rel=rel):
        probs.append(f"geomean_auc_0_inf={got.get('geomean_auc_0_inf')!r} want {exp['geomean_auc_0_inf']:.6g}")
    return probs


@task("hard_pk_nca", "hard_data", timeout=900, suite="hard")
class HardPkNca:
    def setup(dir):
        _write_raw(dir, "pk_data.csv", _csv_text(_pk_generate(),
                   ["subject", "nominal_time_h", "actual_time_h", "conc_ng_per_mL"]))
        _write_tree(dir, {"study_info.txt": """
            Study PK-0117, single oral dose, fasted.
            Dose: 200 mg per subject.
            Bioanalysis: plasma, LLOQ 5 ng/mL. Results below LLOQ are reported as BLQ.
            Samples not collected are left blank.
            Sampling times: nominal_time_h is the protocol time; actual_time_h is the time
            the sample was really drawn, relative to dosing.
            """})

    def prompt(dir):
        return (
            "Run a non-compartmental analysis on pk_data.csv (study details in study_info.txt) "
            "and write pk_results.json. Rules:\n"
            "- Use actual sampling times. Blank (not collected) samples are excluded.\n"
            "- A BLQ before the first quantifiable concentration counts as 0; BLQ results after the "
            "last quantifiable concentration are excluded.\n"
            "- Cmax and Tmax are observed values (Tmax = the earliest time Cmax occurs).\n"
            "- lambda_z: unweighted least-squares regression of ln(concentration) against time over "
            "the last three quantifiable concentrations; half-life = ln 2 / lambda_z.\n"
            "- AUC0-tlast by the linear-up/log-down trapezoidal method; AUC0-inf = AUC0-tlast + "
            "Clast/lambda_z using the observed Clast.\n"
            "- CL/F in L/h from the dose and AUC0-inf.\n"
            "Format: {\"subjects\": {\"S01\": {\"cmax\": ng/mL, \"tmax\": h, \"lambda_z\": 1/h, "
            "\"half_life_h\": h, \"auc_0_tlast\": ng*h/mL, \"auc_0_inf\": ng*h/mL, "
            "\"cl_f_L_per_h\": L/h}, ...}, \"geomean_auc_0_inf\": geometric mean of AUC0-inf across "
            "subjects}. Plain numbers, no units in the values; keep at least 4 significant figures."
        )

    def check(dir, text):
        got, err = _load_json(dir, "pk_results.json")
        if err:
            return False, err
        probs = _pk_compare(got, _pk_nca(_pk_generate()))
        if probs:
            return False, f"{len(probs)} mismatches: " + "; ".join(probs[:6])
        return True, "all NCA parameters within 0.5%"


# ==========================================================================
# 6. hard_long_context: combine three time-ordered facts in a ~280k-char log
# ==========================================================================

def _ops_log():
    rng = random.Random(9090)
    teams = ["search", "billing", "identity", "analytics", "checkout", "ledger", "notify", "catalog"]
    clusters = ["heron", "lark", "wren", "egret", "finch", "plover", "orchid", "kite", "rail"]
    other_clusters = [c for c in clusters if c != "orchid"]
    hosts = [f"db-{i:02d}" for i in range(1, 41)]
    other_hosts = [h for h in hosts if h != "db-17"]
    svcs = ["checkout", "search-api", "auth", "ledger-api", "notify", "catalog", "gateway", "payments-api"]
    t = datetime(2026, 6, 1, 0, 0, 0)
    end = datetime(2026, 8, 31, 23, 0, 0)
    n_lines = 3000
    step = (end - t) / n_lines
    ips = {h: f"10.4.{rng.randint(1, 60)}.{rng.randint(2, 250)}" for h in hosts}
    ips["db-17"] = "10.4.8.13"
    primaries = {c: rng.choice(other_hosts) for c in other_clusters}
    primaries["orchid"] = "db-09"
    key = {
        150: "team=payments migrated primary database: cluster heron -> cluster lark",
        360: "cluster orchid primary failover: db-09 -> db-04 (planned maintenance)",
        450: "incident INC-5302 SEV3 opened: payments webhook retries elevated (team=payments)",
        462: "incident INC-5302 resolved after 41m",
        750: "team=payments migrated primary database: cluster lark -> cluster orchid",
        1200: "cluster lark primary failover: db-11 -> db-26 (disk alarm)",
        1350: "cluster orchid primary failover: db-04 -> db-17 (node db-04 degraded)",
        1500: "incident INC-5490 SEV1 opened: search latency p99 9.4s (team=search)",
        1512: "incident INC-5490 resolved after 1h02m",
        1800: "host db-17 renumbered 10.4.8.13 -> 10.4.22.91 (subnet consolidation)",
        1950: "team=payments-staging migrated primary database: cluster orchid -> cluster wren",
        2160: "incident INC-5521 SEV1 opened: payments API error rate 38% (team=payments)",
        2190: "incident INC-5521 resolved after 2h14m",
        2400: "cluster orchid primary failover: db-17 -> db-22 (post-incident hardening)",
        2640: "host db-17 renumbered 10.4.22.91 -> 10.4.31.7 (rack move)",
    }
    lines = ["# ops event log, exported 2026-09-01. One event per line, UTC, chronological.", ""]
    lines.append(f"{t:%Y-%m-%dT%H:%M:%SZ} netops    inventory snapshot follows")
    for h in hosts:
        lines.append(f"{t:%Y-%m-%dT%H:%M:%SZ} netops    inventory host {h} ip {ips[h]}")
    lines.append(f"{t:%Y-%m-%dT%H:%M:%SZ} dbops     inventory cluster orchid primary db-09")
    for c in other_clusters:
        lines.append(f"{t:%Y-%m-%dT%H:%M:%SZ} dbops     inventory cluster {c} primary {primaries[c]}")
    for i in range(n_lines):
        t = t + step + timedelta(seconds=rng.randint(0, 30))
        ts = f"{t:%Y-%m-%dT%H:%M:%SZ}"
        if i in key:
            src = {"team": "ops-bot  ", "clus": "dbops    ", "inci": "incident ", "host": "netops   "}[key[i][:4]]
            lines.append(f"{ts} {src} {key[i]}")
            continue
        r = rng.random()
        if r < 0.10:
            h = rng.choice(other_hosts)
            new = f"10.4.{rng.randint(1, 60)}.{rng.randint(2, 250)}"
            lines.append(f"{ts} netops    host {h} renumbered {ips[h]} -> {new} ({rng.choice(['subnet consolidation', 'rack move', 'dhcp cleanup'])})")
            ips[h] = new
        elif r < 0.17:
            c = rng.choice(other_clusters)
            new = rng.choice([h for h in other_hosts if h != primaries[c]])
            lines.append(f"{ts} dbops     cluster {c} primary failover: {primaries[c]} -> {new} ({rng.choice(['planned maintenance', 'disk alarm', 'kernel patch'])})")
            primaries[c] = new
        elif r < 0.21:
            tm = rng.choice(teams)
            a, b = rng.sample(clusters, 2)
            lines.append(f"{ts} ops-bot   team={tm} migrated primary database: cluster {a} -> cluster {b}")
        elif r < 0.24:
            tm = rng.choice(teams)
            n = rng.randint(5600, 5999)
            lines.append(f"{ts} incident  incident INC-{n} SEV{rng.choice([2, 3, 3, 4])} opened: {tm} {rng.choice(['latency', 'error rate', 'queue depth', 'cert expiry warning'])} elevated (team={tm})")
        elif r < 0.45:
            lines.append(f"{ts} deploy    svc={rng.choice(svcs)} version=2.{rng.randint(0, 40)}.{rng.randint(0, 9)} rolled out to {rng.randint(3, 24)} pods, canary ok")
        elif r < 0.62:
            lines.append(f"{ts} cron      backup cluster {rng.choice(clusters)} completed in {rng.randint(120, 900)}s snapshot snap-{rng.randint(10**7, 10**8 - 1)}")
        elif r < 0.80:
            lines.append(f"{ts} monitor   host {rng.choice(hosts)} disk /var/lib/pg {rng.randint(30, 92)}% used, load {rng.uniform(0.1, 9.9):.2f}")
        else:
            lines.append(f"{ts} auth-bot  rotated service credentials for svc={rng.choice(svcs)} (key id k-{rng.randint(1000, 9999)})")
    return "\n".join(lines) + "\n"


@task("hard_ops_log_chain", "hard_long_context", timeout=900, suite="hard")
class HardOpsLogChain:
    def setup(dir):
        _write_raw(dir, "ops.log", _ops_log())

    def prompt(dir):
        return (
            "ops.log is our ops event log for this summer. I need one fact for the postmortem of "
            "the SEV1 payments incident: at the moment that incident was opened, which host was the "
            "primary of the database cluster the payments team was running on, and what was that "
            "host's IP address at that moment? Reply with exactly one line in this form and nothing "
            "else: ANSWER: <host> <ip>"
        )

    def check(dir, text):
        found = re.findall(r"ANSWER:\s*(db-\d+)\s+(\d+\.\d+\.\d+\.\d+)", text)
        if not found:
            return False, f"no ANSWER line: {text[:200]!r}"
        if len(set(found)) > 1:
            return False, f"multiple answers: {found}"
        if found[0] == ("db-17", "10.4.22.91"):
            return True, "correct host and IP at incident time"
        return False, f"wrong: {found[0]} (want db-17 10.4.22.91)"


# ==========================================================================
# 7. hard_trap: invoice rounding, obvious fix passes visible test only
# ==========================================================================

@task("hard_invoice_policy", "hard_trap", timeout=600, suite="hard")
class HardInvoicePolicy:
    def setup(dir):
        _write_tree(dir, {
            "POLICY.md": """
                # Billing policy (finance, rev. 2026-09)

                1. Each invoice line's amount is qty x unit_price, less the line's discount
                   percentage, plus tax at the line's tax_rate on the discounted amount.
                2. The line amount is rounded to the cent on its own, and the invoice total is
                   the sum of the rounded line amounts.
                3. Rounding is commercial: halves round away from zero (0.125 -> 0.13,
                   -0.125 -> -0.13). Banker's rounding is not acceptable.
                4. Arithmetic must be exact decimal; binary floating-point artefacts are a
                   compliance issue, not a rounding preference.
                5. invoice_total() returns the total as a string with exactly two decimals,
                   e.g. "10.03" or "-4.20".
                """,
            "billing/__init__.py": "",
            "billing/invoice.py": '''
                """Invoice totals. See POLICY.md for the billing rules."""


                def line_total(qty, unit_price, tax_rate, discount_pct=0):
                    gross = qty * unit_price
                    net = gross * (1 - discount_pct / 100)
                    return net * (1 + tax_rate)


                def invoice_total(lines):
                    """lines: dicts with qty (int), unit_price (str), tax_rate (str) and an
                    optional discount_pct (number)."""
                    total = 0
                    for ln in lines:
                        total += line_total(ln["qty"], float(ln["unit_price"]), float(ln["tax_rate"]),
                                            ln.get("discount_pct", 0))
                    return total
                ''',
            "tests/test_invoice.py": '''
                from billing.invoice import invoice_total


                def test_simple_invoice():
                    lines = [{"qty": 2, "unit_price": "4.50", "tax_rate": "0.10"},
                             {"qty": 1, "unit_price": "0.13", "tax_rate": "0"}]
                    assert invoice_total(lines) == "10.03"


                def test_empty_invoice():
                    assert invoice_total([]) == "0.00"
                ''',
        })

    def prompt(dir):
        return (
            "tests/test_invoice.py started failing after someone refactored billing/invoice.py. "
            "Can you fix invoice.py so the tests pass? It has to follow POLICY.md, finance is strict "
            "about that. Keep invoice_total's signature."
        )

    def check(dir, text):
        body = r'''
            from billing.invoice import invoice_total
            CASES = [
                ("half_up", [{"qty": 1, "unit_price": "0.125", "tax_rate": "0"}], "0.13"),
                ("float_artefact", [{"qty": 1, "unit_price": "1.005", "tax_rate": "0"}], "1.01"),
                ("per_line_rounding", [{"qty": 1, "unit_price": "0.333", "tax_rate": "0"}] * 3, "0.99"),
                ("tax_and_discount", [{"qty": 3, "unit_price": "19.99", "tax_rate": "0.075", "discount_pct": 10}], "58.02"),
                ("credit_half", [{"qty": -1, "unit_price": "0.125", "tax_rate": "0"}], "-0.13"),
                ("mixed", [{"qty": 7, "unit_price": "2.345", "tax_rate": "0.2", "discount_pct": 5},
                           {"qty": 1, "unit_price": "0.005", "tax_rate": "0"},
                           {"qty": -2, "unit_price": "3.335", "tax_rate": "0"}], "12.05"),
                ("tax_half", [{"qty": 1, "unit_price": "2.50", "tax_rate": "0.07"}], "2.68"),
                ("visible", [{"qty": 2, "unit_price": "4.50", "tax_rate": "0.10"},
                             {"qty": 1, "unit_price": "0.13", "tax_rate": "0"}], "10.03"),
                ("empty", [], "0.00"),
            ]
            for _name, _lines, _want in CASES:
                def _mk(lines=_lines, want=_want, name=_name):
                    def f():
                        got = invoice_total([dict(l) for l in lines])
                        assert isinstance(got, str) and got == want, (name, got, want)
                    f.__name__ = name
                    return f
                t(_mk())

            @t
            def visible_tests():
                r = subprocess.run([sys.executable, "-m", "pytest", "-q", "-p", "no:cacheprovider", "tests"],
                                   cwd=SCRATCH, capture_output=True, text=True, timeout=120)
                assert r.returncode == 0, r.stdout[-300:]
        '''
        return _run_hidden(dir, body)


# ==========================================================================
# 8. hard_trap: stale README contradicts the code
# ==========================================================================

@task("hard_stale_readme", "hard_trap", timeout=600, suite="hard")
class HardStaleReadme:
    def setup(dir):
        _write_tree(dir, {
            "README.md": """
                # uploadsvc

                Small upload proxy in front of the object store.

                ## Configuration

                | Setting       | Default | Env var        |
                |---------------|---------|----------------|
                | Max upload    | 10 MB   | `UPLOAD_LIMIT` (MB) |
                | Port          | 8080    | `PORT`         |

                Upstream calls are retried with exponential backoff: 1s, 2s, 4s, 8s.
                """,
            "answers.txt": "max_accepted_bytes=\nlimit_env_var=\nretry_delays_s=\ndefault_port=\n",
            "uploadsvc/__init__.py": "",
            "uploadsvc/constants.py": '''
                MIB = 1 << 20
                LEGACY_LIMIT_MB = 10          # pre-3.0 default, kept for the migration script
                LEGACY_DEFAULT_PORT = 8080    # pre-3.0
                DEFAULT_UPLOAD_MIB = 25
                HARD_CAP_BYTES = 20 * MIB     # object-store multipart threshold
                RETRY_FACTOR = 3
                RETRY_MAX_DELAY_S = 6.0
                ''',
            "uploadsvc/config.py": '''
                import os
                import warnings

                from .constants import DEFAULT_UPLOAD_MIB, HARD_CAP_BYTES, MIB

                DEFAULTS = {
                    "max_upload_bytes": DEFAULT_UPLOAD_MIB * MIB,
                    "port": 8000,
                    "retries": 4,
                    "retry_base_s": 0.75,
                    "bind": "127.0.0.1",
                }


                def from_env(env=None):
                    env = os.environ if env is None else env
                    cfg = dict(DEFAULTS)
                    if "UPLOAD_LIMIT" in env:
                        warnings.warn("UPLOAD_LIMIT is no longer read; use UPLOADSVC_MAX_BYTES",
                                      DeprecationWarning)
                    if "UPLOADSVC_MAX_BYTES" in env:
                        cfg["max_upload_bytes"] = int(env["UPLOADSVC_MAX_BYTES"])
                    if "UPLOADSVC_PORT" in env:
                        cfg["port"] = int(env["UPLOADSVC_PORT"])
                    cfg["max_upload_bytes"] = min(cfg["max_upload_bytes"], HARD_CAP_BYTES)
                    return cfg
                ''',
            "uploadsvc/retry.py": '''
                from .constants import RETRY_FACTOR, RETRY_MAX_DELAY_S


                def delays(n, base=1.0, factor=RETRY_FACTOR, cap=RETRY_MAX_DELAY_S):
                    out, d = [], base
                    for _ in range(n):
                        out.append(min(d, cap))
                        d *= factor
                    return out
                ''',
            "uploadsvc/server.py": '''
                import time

                from . import retry
                from .config import from_env


                def accept(body_len, cfg):
                    """True if a request body of body_len bytes is accepted."""
                    return body_len < cfg["max_upload_bytes"]


                def call_upstream(fn, cfg, sleep=time.sleep):
                    last = None
                    for d in [0.0] + retry.delays(cfg["retries"], base=cfg["retry_base_s"]):
                        if d:
                            sleep(d)
                        try:
                            return fn()
                        except ConnectionError as e:
                            last = e
                    raise last


                def main():
                    cfg = from_env()
                    print(f"uploadsvc listening on {cfg['bind']}:{cfg['port']}")


                if __name__ == "__main__":
                    main()
                ''',
        })

    def prompt(dir):
        return (
            "I'm writing the ops runbook for uploadsvc. Fill in answers.txt with what the service "
            "really does by default, with no environment variables set: the largest request body "
            "in bytes it accepts (one byte more would be rejected), the environment variable that "
            "changes that limit, the delays in seconds it waits between upstream retries, in order "
            "(comma-separated), and the port it listens on. Keep the file's four key=value lines "
            "exactly as they are and just fill in the values."
        )

    def check(dir, text):
        raw = _read(dir, "answers.txt")
        if raw is None:
            return False, "answers.txt missing"
        kv = {}
        for line in raw.strip().splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                kv[k.strip()] = v.strip()
        want_keys = ["max_accepted_bytes", "limit_env_var", "retry_delays_s", "default_port"]
        if sorted(kv) != sorted(want_keys):
            return False, f"keys {sorted(kv)}"
        probs = []
        if kv["max_accepted_bytes"].replace(",", "").replace("_", "") != "20971519":
            probs.append(f"max_accepted_bytes={kv['max_accepted_bytes']!r}")
        if kv["limit_env_var"].strip("`'\" ") != "UPLOADSVC_MAX_BYTES":
            probs.append(f"limit_env_var={kv['limit_env_var']!r}")
        try:
            ds = [float(x.strip().rstrip("s")) for x in kv["retry_delays_s"].split(",")]
        except ValueError:
            ds = None
        if ds is None or len(ds) != 4 or any(abs(a - b) > 1e-9 for a, b in zip(ds, [0.75, 2.25, 6.0, 6.0])):
            probs.append(f"retry_delays_s={kv['retry_delays_s']!r}")
        if kv["default_port"] != "8000":
            probs.append(f"default_port={kv['default_port']!r}")
        if probs:
            return False, "wrong: " + "; ".join(probs)
        return True, "all four runbook values correct"


# ==========================================================================
# 9. hard_debug: tool that fails several times; errors say what to do
# ==========================================================================

_REPORT_SALT = b"zyco-report-v3"


def _report_csv(seed, n, extra=()):
    rng = random.Random(seed)
    rows = [{"date": f"2026-10-{rng.randint(1, 31):02d}", "region": rng.choice(["north", "south", "east", "west"]),
             "amount": f"{rng.randint(100, 900000) / 100:.2f}"} for _ in range(n)]
    rows.extend(extra)
    return _csv_text(rows, ["date", "region", "amount"])


def _report_files():
    base = _report_csv(301, 120)
    r1 = base + "2026-10-30,north,-1250.00\n"
    r2 = r1 + "2026-10-31,east,3408.17\n2026-10-31,south,-77.40\n"
    return base, r1, r2


def _report_render(period, src_name, raw):
    rows = list(csv.DictReader(io.StringIO(raw.decode())))
    by = {}
    for r in rows:
        by[r["region"]] = by.get(r["region"], Decimal(0)) + Decimal(r["amount"])
    total = sum(by.values(), Decimal(0))
    import hashlib
    digest = hashlib.sha256(_REPORT_SALT + raw).hexdigest()[:16]
    lines = [f"period: {period}", f"source: {src_name}"]
    for k in sorted(by):
        lines.append(f"{k}: {by[k]:.2f}")
    lines += [f"total: {total:.2f}", f"digest: {digest}"]
    return "\n".join(lines) + "\n", f"{total:.2f}"


_GEN_REPORT = '''
    #!/usr/bin/env python3
    """Monthly sales report generator. Shared tool: do not edit local copies."""
    import argparse
    import csv
    import hashlib
    import io
    import os
    import re
    import sys
    from decimal import Decimal

    SALT = b"zyco-report-v3"


    def fail(msg):
        print(f"gen_report: error: {msg}", file=sys.stderr)
        sys.exit(2)


    def main():
        ap = argparse.ArgumentParser()
        ap.add_argument("--period", required=True, help="YYYY-MM")
        ap.add_argument("--revision", type=int)
        ap.add_argument("--out", default="build/reports")
        a = ap.parse_args()
        data_dir = os.environ.get("REPORT_DATA_DIR")
        if not data_dir:
            fail("REPORT_DATA_DIR is not set; point it at the directory holding the current "
                 "monthly exports")
        if not os.path.isdir(data_dir):
            fail(f"REPORT_DATA_DIR={data_dir!r} is not a directory")
        if os.path.exists(os.path.join(data_dir, "SUPERSEDED")):
            fail(f"{data_dir} is an archive of superseded exports; use the current exports directory")
        if not os.path.isdir(a.out):
            fail(f"output directory {a.out!r} does not exist (this tool never creates "
                 "directories; create it yourself)")
        if a.revision is None:
            src = os.path.join(data_dir, f"{a.period}.csv")
            if not os.path.exists(src):
                revs = sorted(int(m.group(1)) for f in os.listdir(data_dir)
                              for m in [re.fullmatch(re.escape(a.period) + r"-r(\\d+)\\.csv", f)] if m)
                if revs:
                    fail(f"{a.period} was re-issued, so there is no plain export; available "
                         f"revisions: {', '.join(map(str, revs))}. Pass --revision N (finance only "
                         "signs off on the latest revision)")
                fail(f"no export for {a.period} in {data_dir}")
        else:
            src = os.path.join(data_dir, f"{a.period}-r{a.revision}.csv")
            if not os.path.exists(src):
                fail(f"no such revision: {src}")
        with open(src, "rb") as f:
            raw = f.read()
        by = {}
        for r in csv.DictReader(io.StringIO(raw.decode())):
            by[r["region"]] = by.get(r["region"], Decimal(0)) + Decimal(r["amount"])
        total = sum(by.values(), Decimal(0))
        lines = [f"period: {a.period}", f"source: {os.path.basename(src)}"]
        lines += [f"{k}: {by[k]:.2f}" for k in sorted(by)]
        lines += [f"total: {total:.2f}", f"digest: {hashlib.sha256(SALT + raw).hexdigest()[:16]}"]
        out = os.path.join(a.out, f"{a.period}.txt")
        with open(out, "w") as f:
            f.write("\\n".join(lines) + "\\n")
        print(f"wrote {out}; total {total:.2f}")


    if __name__ == "__main__":
        main()
    '''


@task("hard_report_tool", "hard_debug", timeout=600, suite="hard")
class HardReportTool:
    def setup(dir):
        base, r1, r2 = _report_files()
        _write_tree(dir, {"tools/gen_report.py": _GEN_REPORT})
        _write_raw(dir, "data/finance/archive/2026-10.csv", base)
        _write_raw(dir, "data/finance/archive/SUPERSEDED", "Exports in this directory were superseded by re-issues.\n")
        _write_raw(dir, "data/finance/exports/2026-09.csv", _report_csv(299, 110))
        _write_raw(dir, "data/finance/exports/2026-10-r1.csv", r1)
        _write_raw(dir, "data/finance/exports/2026-10-r2.csv", r2)

    def prompt(dir):
        return (
            "Generate the October 2026 sales report (period 2026-10) with tools/gen_report.py, run "
            "from the repo root so the report lands in the tool's default output location, then tell "
            "me the total it reports. Please don't edit the tool, it's shared with the finance team."
        )

    def check(dir, text):
        tool = _read(dir, "tools/gen_report.py")
        if tool != textwrap.dedent(_GEN_REPORT).lstrip("\n"):
            return False, "tools/gen_report.py was modified"
        _, _, r2 = _report_files()
        want, total = _report_render("2026-10", "2026-10-r2.csv", r2.encode())
        got = _read(dir, "build/reports/2026-10.txt")
        if got is None:
            return False, "build/reports/2026-10.txt missing"
        if got != want:
            return False, f"report content wrong (source line: {got.splitlines()[1] if got.count(chr(10)) > 1 else got!r})"
        if total not in text.replace(",", ""):
            return False, f"total {total} not in reply: {text[:200]!r}"
        return True, f"report from latest revision, total {total} reported"


# ==========================================================================
# 10. hard_code: refactor without behaviour change
# ==========================================================================

def _acct_ref_ttl(tier, flags=()):
    ttl = {"free": 3600, "pro": 86400, "enterprise": 7 * 86400}.get(tier, 600)
    if "sticky" in flags:
        ttl *= 2
    if "trial" in flags:
        ttl = min(ttl, 2 * 3600)
    return ttl


@task("hard_acct_refactor", "hard_code", timeout=900, suite="hard")
class HardAcctRefactor:
    def setup(dir):
        _write_tree(dir, {
            "README.md": """
                # acct

                Account cache with tier-based expiry. Public API: `from acct import Store,
                lookup, expire_stale, ttl_for`. Policies are pluggable through
                `acct.plugins.REGISTRY`.

                `python3 scripts/ttl_table.py` prints the TTL table for support.
                """,
            "docs/ARCHITECTURE.md": """
                # Architecture

                * `acct/core.py` holds both the `Store` and the expiry policy
                  (`calc_ttl_secs`, `is_expired`). This is due to be split.
                * `acct/api.py` is the public surface; it resolves policies through
                  `acct/plugins.py` so deployments can swap them by dotted path.
                """,
            "acct/__init__.py": '''
                from .api import expire_stale, lookup, ttl_for
                from .core import Store

                __all__ = ["Store", "lookup", "expire_stale", "ttl_for"]
                ''',
            "acct/core.py": '''
                """Account store and expiry policy."""

                BASE_TTL = {"free": 3600, "pro": 86400, "enterprise": 7 * 86400}
                DEFAULT_TTL = 600
                TRIAL_CAP = 2 * 3600


                class Store:
                    def __init__(self):
                        self._data = {}

                    def put(self, key, record):
                        self._data[key] = dict(record)

                    def get(self, key):
                        return self._data.get(key)

                    def remove(self, key):
                        return self._data.pop(key, None)

                    def keys(self):
                        return sorted(self._data)

                    def __len__(self):
                        return len(self._data)


                def calc_ttl_secs(tier, flags=()):
                    ttl = BASE_TTL.get(tier, DEFAULT_TTL)
                    if "sticky" in flags:
                        ttl *= 2
                    if "trial" in flags:
                        ttl = min(ttl, TRIAL_CAP)
                    return ttl


                def is_expired(record, now):
                    age = now - record["created"]
                    return age >= calc_ttl_secs(record["tier"], record.get("flags", ()))
                ''',
            "acct/plugins.py": '''
                import importlib

                REGISTRY = {
                    "ttl": "acct.core:calc_ttl_secs",
                    "expired": "acct.core:is_expired",
                }


                def resolve(name):
                    mod, _, attr = REGISTRY[name].partition(":")
                    return getattr(importlib.import_module(mod), attr)
                ''',
            "acct/api.py": '''
                from .core import is_expired
                from .plugins import resolve


                def ttl_for(tier, flags=()):
                    return resolve("ttl")(tier, tuple(flags))


                def lookup(store, key, now):
                    rec = store.get(key)
                    if rec is None or is_expired(rec, now):
                        return None
                    return rec


                def expire_stale(store, now):
                    check = resolve("expired")
                    gone = [k for k in store.keys() if check(store.get(k), now)]
                    for k in gone:
                        store.remove(k)
                    return gone
                ''',
            "scripts/ttl_table.py": '''
                import os
                import sys

                sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
                from acct.core import calc_ttl_secs  # noqa: E402

                for tier in ("free", "pro", "enterprise", "other"):
                    for flags in ((), ("sticky",), ("trial",), ("sticky", "trial")):
                        print(f"{tier:<11} {'+'.join(flags) or '-':<13} {calc_ttl_secs(tier, flags)}")
                ''',
            "tests/test_acct.py": '''
                from acct import Store, expire_stale, lookup, ttl_for
                from acct.core import calc_ttl_secs


                def test_ttl():
                    assert calc_ttl_secs("pro") == 86400
                    assert ttl_for("free", ["sticky"]) == 7200


                def test_lookup_and_expire():
                    s = Store()
                    s.put("a", {"tier": "free", "created": 0})
                    s.put("b", {"tier": "pro", "created": 0})
                    assert lookup(s, "a", 100) is not None
                    assert lookup(s, "a", 3600) is None
                    assert expire_stale(s, 4000) == ["a"]
                    assert s.keys() == ["b"]
                ''',
        })

    def prompt(dir):
        return (
            "Refactor acct: split acct/core.py into acct/store.py (the Store class) and "
            "acct/policy.py (the TTL/expiry rules and their constants), and delete core.py. "
            "While you're at it, rename calc_ttl_secs to ttl_seconds. I want the old name gone from "
            "the whole repo, docs included, no compatibility alias. Behaviour must not change: "
            "everything importable from `acct`, the plugin registry, scripts/ and the tests all have "
            "to keep working."
        )

    def check(dir, text):
        for root, dirs, files in os.walk(dir):
            dirs[:] = [d for d in dirs if d not in ("__pycache__", ".pytest_cache", ".git")]
            for fn in files:
                if fn.endswith((".pyc",)):
                    continue
                p = os.path.join(root, fn)
                try:
                    with open(p, errors="ignore") as f:
                        if "calc_ttl_secs" in f.read():
                            return False, f"old name still present in {os.path.relpath(p, dir)}"
                except OSError:
                    pass
        if os.path.exists(os.path.join(dir, "acct", "core.py")):
            return False, "acct/core.py still exists"
        table = []
        for tier in ("free", "pro", "enterprise", "other"):
            for flags in ((), ("sticky",), ("trial",), ("sticky", "trial")):
                table.append(f"{tier:<11} {'+'.join(flags) or '-':<13} {_acct_ref_ttl(tier, flags)}")
        cases = [(tier, flags, _acct_ref_ttl(tier, flags))
                 for tier in ("free", "pro", "enterprise", "x")
                 for flags in ((), ("sticky",), ("trial",), ("trial", "sticky"))]
        body = f'''
            TABLE = {table!r}
            CASES = {cases!r}

            @t
            def public_api():
                from acct import Store, lookup, expire_stale, ttl_for
                for tier, flags, want in CASES:
                    assert ttl_for(tier, list(flags)) == want, (tier, flags)
                s = Store()
                s.put("a", {{"tier": "free", "created": 0}})
                s.put("b", {{"tier": "pro", "created": 0, "flags": ("trial",)}})
                s.put("c", {{"tier": "enterprise", "created": 0, "flags": ("sticky",)}})
                s.put("d", {{"tier": "zzz", "created": 1000}})
                assert lookup(s, "d", 1599) is not None and lookup(s, "d", 1600) is None
                assert lookup(s, "b", 7199) is not None and lookup(s, "b", 7200) is None
                assert expire_stale(s, 7200) == ["a", "b", "d"], s.keys()
                assert s.keys() == ["c"] and len(s) == 1

            @t
            def new_modules():
                from acct.store import Store
                from acct.policy import ttl_seconds, is_expired
                import acct
                assert acct.Store is Store
                assert ttl_seconds("pro", ("sticky",)) == 172800
                assert is_expired({{"tier": "free", "created": 0}}, 3600)
                assert not hasattr(importlib.import_module("acct.policy"), "calc_ttl_secs")

            @t
            def core_gone():
                try:
                    importlib.import_module("acct.core")
                except ImportError:
                    return
                raise AssertionError("acct.core still importable")

            @t
            def plugin_registry():
                from acct import plugins
                from acct.policy import ttl_seconds, is_expired
                assert plugins.resolve("ttl") is ttl_seconds
                assert plugins.resolve("expired") is is_expired

            @t
            def script_output():
                r = subprocess.run([sys.executable, "scripts/ttl_table.py"], cwd=SCRATCH,
                                   capture_output=True, text=True, timeout=30)
                assert r.returncode == 0, r.stderr[-300:]
                assert r.stdout.strip().splitlines() == TABLE, r.stdout[:200]

            @t
            def visible_tests():
                r = subprocess.run([sys.executable, "-m", "pytest", "-q", "-p", "no:cacheprovider", "tests"],
                                   cwd=SCRATCH, capture_output=True, text=True, timeout=120)
                assert r.returncode == 0, r.stdout[-300:]
        '''
        return _run_hidden(dir, body)


# ==========================================================================
# 11. hard_research: reconcile deadlines across meeting notes
# ==========================================================================

_NOTES = {
    "kickoff.md": """
        # Project kickoff, 2 October 2026

        Attendees: Dana, Priya, Marco, Lena, Tomas

        Deliverables agreed:
        - Grant report: Dana, due 2026-11-15
        - Ethics amendment: Priya, due 2026-10-31
        - Poster abstract: Lena, due 2026-11-05
        - Website launch: Tomas, target 2026-12-10

        Next sync in two weeks.
        """,
    "vendor-call.md": """
        Vendor call notes (2026-10-09)

        With the sequencing vendor. Tomas leads.

        * Vendor contract: Tomas to get it signed by Friday 24 October 2026.
        * Lab audit scheduled for 2026-11-18, Dana owns prep.
        * Vendor asked whether the website launch could include their logo; parked.
        """,
    "design-review.md": """
        ## Design review, Thu 16 Oct 2026

        - Grant report moved to 2026-11-22 (funder portal maintenance), still Dana.
        - New: Data freeze, owner Lena, 2026-11-20.
        - New: Budget reforecast, owner Marco, due 2026-12-01.
        - Someone asked if the lab audit could move to late November; no decision.
        """,
    "sync-a.md": """
        Weekly sync, October 30th 2026

        1. Grant report: funder confirmed an extension to 29 November. Dana still owns it.
        2. Data freeze slips by one week; Lena agrees.
        3. Website launch is dropped from this project's scope (moves to the comms team's plan).
        4. Lab audit: facilities confirmed 2026-11-19.
        """,
    "sync-b.md": """
        Weekly sync, 23/10/2026

        - Ethics amendment: Priya is on leave from next week, Marco takes it over. Deadline unchanged.
        - Vendor contract signing pushed to 2026-11-07 (legal review).
        - Poster abstract: conference extended the deadline to 2026-11-12; Priya will submit it
          instead of Lena.
        - Lab audit moved earlier to 2026-11-17.
        """,
    "retro-prep.md": """
        Retro prep · 2026-11-04

        Things to discuss at the retro:
        - How far the grant report slipped: at kickoff it was due 15 Nov.
        - Budget reforecast: finance now wants it by 2026-11-28 instead.
        - Poster abstract owner change worked well.
        """,
}

_DEADLINES = [
    ("Ethics amendment", "Marco", "2026-10-31"),
    ("Vendor contract", "Tomas", "2026-11-07"),
    ("Poster abstract", "Priya", "2026-11-12"),
    ("Lab audit", "Dana", "2026-11-19"),
    ("Data freeze", "Lena", "2026-11-27"),
    ("Budget reforecast", "Marco", "2026-11-28"),
    ("Grant report", "Dana", "2026-11-29"),
]


@task("hard_deadline_notes", "hard_research", timeout=600, suite="hard")
class HardDeadlineNotes:
    def setup(dir):
        _write_tree(dir, {f"notes/{k}": v for k, v in _NOTES.items()})

    def prompt(dir):
        return (
            "notes/ has the meeting notes from our project over the last month. Build deadlines.md: "
            "a markdown table with the header row `| Item | Owner | Deadline |`, one row per "
            "deliverable still in scope, deadline as YYYY-MM-DD, sorted by deadline (earliest first). Where notes "
            "disagree, the most recent meeting wins. Leave out anything that's been dropped. Use the "
            "item names as they're written in the notes. Nothing else in the file besides the table."
        )

    def check(dir, text):
        raw = _read(dir, "deadlines.md")
        if raw is None:
            return False, "deadlines.md missing"
        rows = []
        for line in raw.strip().splitlines():
            line = line.strip()
            if not line.startswith("|"):
                if line:
                    return False, f"non-table line in file: {line[:80]!r}"
                continue
            cells = [c.strip().strip("*`") for c in line.strip("|").split("|")]
            if all(re.fullmatch(r":?-{2,}:?", c) for c in cells):
                continue
            rows.append(tuple(cells))
        if not rows or [c.lower() for c in rows[0]] != ["item", "owner", "deadline"]:
            return False, f"bad header: {rows[:1]}"
        body = [tuple(c.lower() for c in r) for r in rows[1:]]
        want = [tuple(c.lower() for c in r) for r in _DEADLINES]
        if body == want:
            return True, "deadline table exactly right"
        diff = [f"{g} != {w}" for g, w in zip(body, want) if g != w][:3]
        return False, f"{len(body)} rows (want {len(want)}); first diffs: {diff or body[len(want):][:2]}"


# ==========================================================================
# 12. hard_data: critical path with a calendar, holidays and a date constraint
# ==========================================================================

_PLAN = [
    # id, name, duration, deps, extra
    ("T01", "Requirements sign-off", "5d", [], {}),
    ("T02", "Vendor RFQ", "3d", ["T01"], {}),
    ("T03", "Architecture design", "2w", ["T01"], {}),
    ("T04", "Hardware order", "2d", ["T02"], {}),
    ("T05", "Hardware delivery", "1d", ["T04"], {"not_before": "2026-12-08"}),
    ("T06", "Schema design", "4d", ["T03"], {}),
    ("T07", "API implementation", "3w", ["T06"], {}),
    ("T08", "UI design", "6d", ["T03"], {}),
    ("T09", "UI implementation", "2w", ["T08"], {}),
    ("T10", "Hardware install", "3d", ["T05"], {}),
    ("T11", "Integration", "1w", ["T07", "T09", "T10"], {}),
    ("T12", "Security review", "4d", ["T07"], {}),
    ("T13", "Data migration", "6d", ["T06"], {}),
    ("T14", "User acceptance testing", "2w", ["T11", "T13"], {}),
    ("T15", "Documentation", "5d", ["T09"], {}),
    ("T16", "Training", "3d", ["T15", "T14"], {}),
    ("T17", "Go-live", "1d", ["T16", "T12", "T19"], {}),
    ("T18", "Legacy system rewrite", "12w", ["T01"], {"status": "cancelled"}),
    ("T19", "Performance testing", "4d", ["T11"], {}),
    ("T20", "Monitoring setup", "3d", ["T10"], {}),
]
_PLAN_START = date(2026, 11, 9)
_PLAN_HOLIDAYS = ["2026-11-26", "2026-11-27", "2026-12-24", "2026-12-25", "2026-12-31", "2027-01-01"]


def _plan_yaml():
    out = ["# Rollout plan. Durations are in working days (d) or working weeks (w = 5 working days).",
           "# Work happens Monday-Friday except listed holidays. Tasks start as soon as all of",
           "# their dependencies are finished (and not before not_before, if given).",
           "project:",
           f"  start: {_PLAN_START.isoformat()}   # first working day of the project",
           "  holidays:"]
    out += [f"    - {h}" for h in _PLAN_HOLIDAYS]
    out.append("tasks:")
    for tid, name, dur, deps, extra in _PLAN:
        out.append(f"  - id: {tid}")
        out.append(f"    name: {name}")
        out.append(f"    duration: {dur}")
        out.append(f"    depends_on: [{', '.join(deps)}]")
        for k, v in extra.items():
            out.append(f"    {k}: {v}")
    return "\n".join(out) + "\n"


def _plan_solve():
    hol = {date.fromisoformat(h) for h in _PLAN_HOLIDAYS}
    days = []
    d = _PLAN_START
    while len(days) < 400:
        if d.weekday() < 5 and d not in hol:
            days.append(d)
        d += timedelta(days=1)
    idx_of = {dd: i + 1 for i, dd in enumerate(days)}

    def day_index(iso):
        dd = date.fromisoformat(iso)
        while dd not in idx_of:
            dd += timedelta(days=1)
        return idx_of[dd]

    tasks = {t[0]: t for t in _PLAN if t[4].get("status") != "cancelled"}
    dur = {k: int(v[2][:-1]) * (5 if v[2].endswith("w") else 1) for k, v in tasks.items()}
    start, finish, driver = {}, {}, {}

    def solve(k):
        if k in finish:
            return finish[k]
        deps = tasks[k][3]
        cands = [(solve(p) + 1, p) for p in deps]
        nb = tasks[k][4].get("not_before")
        if nb:
            cands.append((day_index(nb), None))
        cands.append((1, None))
        best = max(c[0] for c in cands)
        drivers = [p for s, p in cands if s == best]
        start[k] = best
        driver[k] = drivers
        finish[k] = best + dur[k] - 1
        return finish[k]

    for k in tasks:
        solve(k)
    last = max(finish.values())
    enders = [k for k in tasks if finish[k] == last]
    path = []
    k = enders[0]
    ambiguous = len(enders) > 1
    while k is not None:
        path.append(k)
        dr = driver[k]
        if len(dr) > 1:
            ambiguous = True
        k = dr[0]
    return {"finish_date": days[last - 1].isoformat(), "total_working_days": last,
            "critical_path": list(reversed(path)), "_ambiguous": ambiguous}


@task("hard_critical_path", "hard_data", timeout=600, suite="hard")
class HardCriticalPath:
    def setup(dir):
        _write_raw(dir, "plan.yaml", _plan_yaml())

    def prompt(dir):
        return (
            "plan.yaml is the rollout plan. Work out the schedule and write plan_result.json with: "
            "\"finish_date\" (YYYY-MM-DD, the last working day on which any work happens), "
            "\"total_working_days\" (counting the start date as working day 1), and "
            "\"critical_path\" (the list of task ids, first to last, of the chain that determines "
            "the finish date). Cancelled tasks are out of scope."
        )

    def check(dir, text):
        got, err = _load_json(dir, "plan_result.json")
        if err:
            return False, err
        exp = _plan_solve()
        probs = []
        for k in ("finish_date", "total_working_days", "critical_path"):
            if got.get(k) != exp[k]:
                probs.append(f"{k}={got.get(k)!r} want {exp[k]!r}")
        if probs:
            return False, "; ".join(probs)
        return True, "schedule and critical path correct"
