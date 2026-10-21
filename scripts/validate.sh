#!/bin/bash
# Single public entry point; Python owns deadlines, results, and cleanup.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$ROOT/scripts/validate.py" "$@"
