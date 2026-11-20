#!/bin/zsh
# Runs the unit tests. Extra arguments go to "swift test" (for example
# --filter WECoreTests).
set -euo pipefail
cd "$(dirname "$0")/.."
# The build folders are links to *.nosync folders, which iCloud Drive does not
# copy to other Macs: create the missing ones.
for link in .build build; do
  [[ -L "$link" && ! -e "$link" ]] && mkdir -p "$(readlink "$link")"
done
swift test "$@"
