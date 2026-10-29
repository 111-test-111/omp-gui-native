#!/usr/bin/env python3
"""Select explicit checks, inspect their plan and execute each dependency once."""
import argparse
import os
from pathlib import Path
import sys

sys.dont_write_bytecode = True

from catalog import TIERS, plan, registry
from support.engine import CheckFailed, Engine


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("areas", nargs="*", help="Explicit behavior areas; omit to list without running")
    parser.add_argument("--tier", choices=TIERS, default="functional")
    parser.add_argument("--dry-run", action="store_true", help="Inspect ordered checks and requirements without side effects")
    parser.add_argument("--omp", action="append", default=[], help="Absolute installed OMP executable (native only); repeat for rpc matrix")
    parser.add_argument("--paper", help="Optional Markdown fixture; required for the preview benchmark")
    args = parser.parse_args(argv)
    if not args.areas:
        print(f'Choose affected areas: make verify TIER={args.tier} AREAS="..."')
        for check in registry().values():
            if check.tier == args.tier:
                print(f"  {check.area:22} {check.description}")
        print("Tiers: " + ", ".join(TIERS) + "; no default full run. GUI acceptance: tests/acceptance/README.md")
        return 0
    try:
        checks = plan(args.areas, args.tier)
    except ValueError as error:
        parser.error(str(error))
    print("Plan: " + " -> ".join(check.id for check in checks), flush=True)
    for check in checks:
        requirements = [*check.tools]
        if check.sources:
            requirements.append("SwiftPM (pinned SwiftMath dependency)" if check.recipe == "math" else "Swift 6 compiler")
        if check.app:
            requirements.append("fresh worktree Dev build")
        if check.tier == "native":
            requirements.append("explicit OMP path; isolated native profile")
        print(f"  {check.id}: {check.description}" + (" [" + "; ".join(requirements) + "]" if requirements else ""), flush=True)
    if args.dry_run:
        return 0
    omp = args.omp or ([os.environ["OMP_EXECUTABLE"]] if os.environ.get("OMP_EXECUTABLE") else [])
    try:
        Engine(Path(__file__).resolve().parents[1], checks, omp, args.paper).execute()
    except KeyboardInterrupt:
        print("Interrupted; no automatic retry.", file=sys.stderr)
        return 130
    except (ValueError, OSError, CheckFailed) as error:
        print(str(error), file=sys.stderr)
        return error.code if isinstance(error, CheckFailed) else 1
    print(f"Passed {len(checks)} selected checks. Stop here unless inputs change.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
