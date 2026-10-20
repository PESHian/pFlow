#!/usr/bin/env bash
# Production requires an explicit Developer ID identity, team and notary profile.
# --testing packages development builds and never produces a trusted receipt.
set -euo pipefail
cd "$(dirname "$0")"
exec python3 scripts/mac_release.py "$@"
