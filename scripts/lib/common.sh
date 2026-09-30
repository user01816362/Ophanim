#!/bin/bash
# Shared shell preamble for all Ophanim scripts.
# Usage: source "$(dirname "$0")/../lib/common.sh"
set -euo pipefail

# Put Apple's toolchain + /usr/bin ahead of any shadowing toolchain on PATH
# (e.g. Anaconda's cctools-port vtool/strip/ld/nm/lipo, which segfault on Mach-O).
if command -v xcrun >/dev/null 2>&1; then
  export PATH="$(dirname "$(xcrun --find clang)"):/usr/bin:/bin:$PATH"
fi

# Repo root (scripts/ may be nested one level, e.g. scripts/test/).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/../../build-ophanim.sh" ]; then
  APP_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
else
  APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi
export APP_ROOT
