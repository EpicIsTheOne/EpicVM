#!/usr/bin/env bash

set -Eeuo pipefail

printf '%s\n' "install.sh is a compatibility entrypoint; use install-epicvm.sh." >&2
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/install-epicvm.sh" "$@"