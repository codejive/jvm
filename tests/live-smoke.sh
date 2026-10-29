#!/usr/bin/env bash
# Optional network check, deliberately separate from the deterministic suite.
ROOT=$(cd "$(dirname "$0")/.." && pwd) || exit 1
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/jvm-live.XXXXXXXX") || exit 1
trap 'rm -rf -- "$TEMP"' EXIT
trap 'exit 1' HUP INT TERM
export HOME="$TEMP/home" XDG_CACHE_HOME="$TEMP/cache"
export XDG_DATA_HOME="$TEMP/data" XDG_CONFIG_HOME="$TEMP/config" XDG_STATE_HOME="$TEMP/state"
mkdir -p "$HOME" || exit 1
"${BASH:-bash}" "$ROOT/jvm" available "$@" || exit 1
# A second invocation exercises the real cached-body path.
"${BASH:-bash}" "$ROOT/jvm" available "$@"
