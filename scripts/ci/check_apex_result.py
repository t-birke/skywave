#!/usr/bin/env python3
"""check_apex_result.py — robustly verify a `sf apex run --json` result file.

WHY THIS EXISTS (do not "simplify" back to jq)
`sf apex run --json` embeds the raw Apex debug log in .result.logs, and that log
contains NUL / control bytes (U+0000–U+001F). Strict JSON parsers (jq) reject them
as unescaped control chars, and capturing the output in a bash $() drops the NULs
and corrupts the document — together they turn a SUCCESSFUL apex run into a false
failure. Python's json.loads(strict=False) tolerates control chars inside strings,
so we read the file (never a shell var) and parse leniently.

Also normalizes the two output shapes sf uses:
  success -> {"status": 0, "result": {"compiled": true, "success": true, "logs": ...}}
  failure -> {"status": <non-0>, "name": ..., "message": ..., "data": {"compiled": ...}}

Exit 0 and echo the freshen marker line if the run compiled AND succeeded; else
print a ::error:: annotation and exit 1.

Usage: python3 scripts/ci/check_apex_result.py <path-to-sf-apex-run-json>
"""
import json
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print("::error::check_apex_result.py needs exactly one arg (the json file)")
        return 2
    with open(sys.argv[1], encoding="utf-8", errors="replace") as fh:
        doc = json.load(fh, strict=False)

    body = doc.get("result") or doc.get("data") or {}
    ok = doc.get("status") == 0 and body.get("compiled") and body.get("success")
    if not ok:
        reason = (
            doc.get("message")
            or body.get("compileProblem")
            or body.get("exceptionMessage")
            or "unknown failure"
        )
        print(f"::error::freshenObservabilityDates.apex did not run cleanly: {reason}")
        return 1

    # Surface the script's own summary line (best-effort; never fatal).
    for line in (body.get("logs") or "").split("\n"):
        if "freshenObservabilityDates:" in line and "USER_DEBUG" in line:
            print(line.split("|")[-1].strip())
            break
    return 0


if __name__ == "__main__":
    sys.exit(main())
