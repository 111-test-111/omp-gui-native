#!/bin/bash
# Compatibility entry point: one-way mirroring is retired. Never rsync --delete
# the shared live store or overwrite per-edition preferences/API credentials.
set -euo pipefail
printf '%s\n' 'Tivano and Tivano Dev now share ~/Library/Application Support/Tivano and ~/.tivano.' 'No copy or deletion was performed. Close the active edition before switching.'
