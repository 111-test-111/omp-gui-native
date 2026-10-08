#!/usr/bin/env python3
"""Set an edition's version, or explicitly let Release catch up to Dev."""
import argparse
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument("edition", choices=["dev", "release"])
parser.add_argument("version", help="Numeric x.y.z, or 'catch-up-dev' for release")
args = parser.parse_args()
path = ROOT / "config" / f"{args.edition}.xcconfig"
version = args.version
if version == "catch-up-dev":
    if args.edition != "release":
        parser.error("Only Release may catch up to Dev")
    version = re.search(r"^MARKETING_VERSION\s*=\s*(\d+\.\d+\.\d+)\s*$", (ROOT / "config/dev.xcconfig").read_text(), re.M)[1]
if not re.fullmatch(r"\d+\.\d+\.\d+", version):
    parser.error("Version must be numeric x.y.z; the app adds Dev's prefix")
text = path.read_text()
build = int(re.search(r"^CURRENT_PROJECT_VERSION\s*=\s*(\d+)\s*$", text, re.M)[1]) + 1
text = re.sub(r"^MARKETING_VERSION\s*=.*$", f"MARKETING_VERSION = {version}", text, flags=re.M)
text = re.sub(r"^CURRENT_PROJECT_VERSION\s*=.*$", f"CURRENT_PROJECT_VERSION = {build}", text, flags=re.M)
path.write_text(text)
print(f"{args.edition}: {'dev-' if args.edition == 'dev' else ''}{version} (build {build})")
