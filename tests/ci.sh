#!/usr/bin/env bash
# Run with the interpreter being tested, never a compatibility-mode substitute.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
case "${1:-}" in
    3.2) [ "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}" = 3.2 ] ;;
    current) [ "${BASH_VERSINFO[0]}" -ge 4 ] ;;
    *) echo 'Usage: <bash-to-test> tests/ci.sh <3.2|current>' >&2; exit 2 ;;
esac
printf 'Testing %s on %s\n' "$BASH_VERSION" "$(uname -a)"
BASH_BIN=$BASH
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/jvm-ci.XXXXXXXX")
trap 'rm -rf -- "$TEMP"' EXIT
trap 'exit 1' HUP INT TERM
mkdir "$TEMP/bin"
# Also cover env-bash shebangs and bare `bash` commands with this interpreter.
ln -s "$BASH_BIN" "$TEMP/bin/bash"
export PATH="$TEMP/bin:$PATH"
bash -c '[ "$BASH_VERSION" = "$1" ]' bash "$BASH_VERSION"
cd "$ROOT"
"$BASH_BIN" -n ./jvm
for script in tests/*.sh; do "$BASH_BIN" -n "$script"; done
"$BASH_BIN" tests/run.sh
case "$(uname -s)" in
    CYGWIN*|MSYS*|MINGW*) "$BASH_BIN" tests/default-native-windows.sh ;;
esac
