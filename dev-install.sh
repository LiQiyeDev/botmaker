#!/usr/bin/env bash
#
# dev-install.sh (umbrella) — install BOTH local library builds into ~/.m2 in one shot, so a generated
# bot picks up your local botmaker-shared AND botmaker-sdk changes without pushing any git tag.
#
# It just runs the two module scripts in dependency order:
#   1. botmaker-shared/dev-install.sh  → com.github.LiQiyeDev:botmaker-shared:0.0.0-SNAPSHOT
#   2. botmaker-sdk/dev-install.sh     → com.github.LiQiyeDev:botmaker-sdk:local-SNAPSHOT
#                                        (its shared dep is pinned to the local 0.0.0-SNAPSHOT above)
#
# Usage:
#   ./dev-install.sh
#   DEV_SDK_VERSION=mine ./dev-install.sh   # forwarded to the SDK script's dev version label

set -euo pipefail

UMBRELLA="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> [1/2] botmaker-shared"
"$UMBRELLA/botmaker-shared/dev-install.sh"

echo
echo "==> [2/2] botmaker-sdk"
"$UMBRELLA/botmaker-sdk/dev-install.sh"

echo
echo "All set. In Studio, pick '${DEV_SDK_VERSION:-local-SNAPSHOT}' from the SDK version dropdown — it's"
echo "auto-listed at the top (New Project, or Project > Manage Libraries) whenever a local build is installed."
