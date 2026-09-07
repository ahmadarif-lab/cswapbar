#!/usr/bin/env bash
# Quick iteration loop: shows a temporary Dock icon (no Info.plist in dev
# mode) but is faster than the full package/install cycle.
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
swift run
