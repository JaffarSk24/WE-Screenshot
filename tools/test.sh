#!/bin/zsh
# Runs the unit tests. Extra arguments go to "swift test" (for example
# --filter WECoreTests).
set -euo pipefail
cd "$(dirname "$0")/.."
swift test "$@"
