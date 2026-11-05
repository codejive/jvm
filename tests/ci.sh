#!/usr/bin/env bash
# Run with the interpreter being tested, never a compatibility-mode substitute.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
case "${1:-}" in
    3.2)
        case "$(uname -s)" in
            CYGWIN*|MSYS*|MINGW*) echo 'Bash 3.2 validation is supported only on Unix.' >&2; exit 1 ;;
        esac
        [ "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}" = 3.2 ] ;;
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
"$BASH_BIN" -n web/install.sh
for script in tests/*.sh; do "$BASH_BIN" -n "$script"; done
"$BASH_BIN" tests/run.sh
"$BASH_BIN" tests/tool-installer.sh
case "$(uname -s)" in
    CYGWIN*|MSYS*|MINGW*)
        "$BASH_BIN" tests/default-native-windows.sh
        # A restricted Cygwin PATH may contain System32 without its PowerShell
        # subdirectory. Include it for the suite's nested PowerShell/CMD calls.
        system_directory=$(cygpath -u -S)
        export PATH="$PATH:$system_directory/WindowsPowerShell/v1.0"
        JVM_TEST_BASH="$(cygpath -aw "$BASH_BIN")" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -aw "$ROOT/tests/tool-installer.ps1")" ;;
esac
