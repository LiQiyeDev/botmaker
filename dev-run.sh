#!/usr/bin/env bash
#
# dev-run.sh (umbrella) — thin wrapper so you can launch the Studio dev loop from the repo root.
#
# The real script lives in botmaker-studio/dev-run.sh (it installs the local shared + sdk, then runs
# the Studio against them). This just forwards all arguments to it.
#
# Usage (identical to botmaker-studio/dev-run.sh):
#   ./dev-run.sh                 # install (shared + sdk), then run the Studio
#   ./dev-run.sh --no-install    # skip install, just run

set -euo pipefail

UMBRELLA="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$UMBRELLA/botmaker-studio/dev-run.sh" "$@"
