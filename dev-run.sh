#!/usr/bin/env bash
#
# dev-run.sh (umbrella) — thin wrapper so you can launch the Studio dev loop from the repo root.
#
# The real script lives in botmaker-studio/dev-run.sh (it dev-installs the local shared + sdk, then runs
# the Studio against them). This just forwards all arguments to it.
#
# Usage (identical to botmaker-studio/dev-run.sh):
#   ./dev-run.sh                 # dev-install (shared + sdk local-SNAPSHOT), then run the Studio
#   ./dev-run.sh --sdk           # install the local SDK as 0.0.0-SNAPSHOT (latest snapshot) instead
#   ./dev-run.sh --no-install    # skip dev-install, just run

set -euo pipefail

UMBRELLA="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$UMBRELLA/botmaker-studio/dev-run.sh" "$@"
