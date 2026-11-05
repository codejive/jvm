#!/usr/bin/env bash
# Run with the interpreter being tested, never a compatibility-mode substitute.
set -eu
CI_STARTED=$SECONDS
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
suite_pids=()
cleanup() {
    local pid
    for pid in "${suite_pids[@]:-}"; do
        [ -z "$pid" ] || { kill -TERM "$pid" 2>/dev/null || :; }
    done
    for pid in "${suite_pids[@]:-}"; do
        [ -z "$pid" ] || { wait "$pid" 2>/dev/null || :; }
    done
    rm -rf -- "$TEMP"
    printf 'TIMING: total: %ss\n' "$((SECONDS-CI_STARTED))"
}
trap cleanup EXIT
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
run_suite() {
    local name=$1 started=$SECONDS status=0
    shift
    "$@" || status=$?
    printf 'TIMING: %s: %ss (exit %s)\n' "$name" "$((SECONDS-started))" "$status"
    return "$status"
}
case "$(uname -s)" in
    CYGWIN*|MSYS*|MINGW*)
        # Bound concurrency to three independent installation suites. Capture
        # separate logs so output and failures cannot interleave or get lost.
        suites=(contracts selection archives)
        for suite in "${suites[@]}"; do
            "$BASH_BIN" tests/install.sh "--$suite" > "$TEMP/$suite.log" 2>&1 &
            suite_pids[${#suite_pids[@]}]=$!
        done
        # A fourth worker runs the remaining independent suites in sequence.
        run_suite discovery "$BASH_BIN" tests/run.sh --discovery
        run_suite home-env "$BASH_BIN" tests/home-env.sh
        run_suite tool-installer "$BASH_BIN" tests/tool-installer.sh
        status=0
        for index in 0 1 2; do
            wait "${suite_pids[$index]}" || status=1
            suite_pids[$index]=
            cat "$TEMP/${suites[$index]}.log"
        done
        [ "$status" -eq 0 ] || exit "$status" ;;
    *)
        run_suite discovery "$BASH_BIN" tests/run.sh --discovery
        run_suite installation "$BASH_BIN" tests/install.sh
        run_suite home-env "$BASH_BIN" tests/home-env.sh
        run_suite tool-installer "$BASH_BIN" tests/tool-installer.sh ;;
esac
case "$(uname -s)" in
    CYGWIN*|MSYS*|MINGW*)
        run_suite native-junction "$BASH_BIN" tests/default-native-windows.sh
        # A restricted Cygwin PATH may contain System32 without its PowerShell
        # subdirectory. Include it for the suite's nested PowerShell/CMD calls.
        system_directory=$(cygpath -u -S)
        export PATH="$PATH:$system_directory/WindowsPowerShell/v1.0"
        run_suite powershell-installer powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -aw "$ROOT/tests/tool-installer.ps1")" ;;
esac
