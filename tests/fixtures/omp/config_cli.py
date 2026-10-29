#!/usr/bin/env python3
"""Forward configuration to real OMP; keep optional provider discovery offline."""
import json
import os
from pathlib import Path
import sys

if len(sys.argv) > 1 and sys.argv[1] == "config":
    root = Path(os.environ["OMP_P3_CONFIG_ROOT"]).resolve()
    configured = Path(os.environ.get("PI_CODING_AGENT_DIR", "/")).resolve()
    repo = Path(__file__).resolve().parents[3]
    if configured != root / "agent" or not root.is_relative_to(repo / "build.noindex/verification/runs"):
        raise SystemExit("Refusing non-isolated native configuration")
    with (root / "calls.jsonl").open("a") as stream:
        stream.write(json.dumps({"command": sys.argv[1:3], "overlayPresent": "PI_CONFIG_FILES" in os.environ}) + "\n")
    executable = os.environ["OMP_P3_REAL_CLI"]
    os.execve(executable, [executable] + sys.argv[1:], os.environ)
elif len(sys.argv) > 1 and sys.argv[1] == "models":
    print(json.dumps({"models": []}))
else:
    for line in sys.stdin:
        command = json.loads(line)
        data = {"providers": []} if command["type"] == "get_login_providers" else {}
        print(json.dumps(dict(type="response", id=command["id"], command=command["type"], success=True, data=data)), flush=True)
