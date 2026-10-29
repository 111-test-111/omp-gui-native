#!/bin/bash
set -euo pipefail
echo "OMP GUI is a local project with no configured public release destination. Use make build or scripts/package_local.sh for local builds." >&2
exit 1
