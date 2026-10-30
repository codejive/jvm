#!/usr/bin/env bash
# Optional native Windows junction smoke: isolated storage, no downloads/JDK use.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
case "$(uname -s)" in CYGWIN*|MSYS*|MINGW*) ;; *) echo 'Windows Bash required' >&2; exit 1 ;; esac
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/jvm-native-default.XXXXXXXX")
cleanup() {
    [ ! -L "$XDG_DATA_HOME/jvm/default" ] || rm -- "$XDG_DATA_HOME/jvm/default"
    rm -rf -- "$TEMP"
}
export HOME="$TEMP/home" XDG_DATA_HOME="$TEMP/data spaces & bang! percent%"
export XDG_CACHE_HOME="$TEMP/cache" XDG_CONFIG_HOME="$TEMP/config" XDG_STATE_HOME="$TEMP/state"
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
machine=$(uname -m)
case "$machine" in x86_64|amd64|AMD64) arch=x86_64 ;; aarch64|arm64|ARM64) arch=aarch64 ;; *) exit 1 ;; esac
for major in 21 25; do
    home=$XDG_DATA_HOME/jvm/jdks/$major+1-test
    mkdir -p "$home/bin"
    # Real native executables prove traversal, without using an actual JDK.
    cp "$(command -v cmd.exe)" "$home/bin/java.exe"
    cp "$(command -v cmd.exe)" "$home/bin/javac.exe"
    printf 'jvm-install-v2\t%s+1-test\ttest\t%s+1\thotspot\twindows\t%s\t.\thttps://invalid.test/jdk\t%064d\tzip\t0\n' "$major" "$major" "$arch" 0 > "$home/.jvm-manifest"
done
bash "$ROOT/jvm" install 21+1-test
[ -L "$XDG_DATA_HOME/jvm/default" ]
bash "$ROOT/jvm" default 25
[ "$XDG_DATA_HOME/jvm/default" -ef "$XDG_DATA_HOME/jvm/jdks/25+1-test" ]
MSYS2_ARG_CONV_EXCL='*' "$XDG_DATA_HOME/jvm/default/bin/java.exe" /d /c exit 0
# Native path conversion through the stable junction and explicit inventory home.
for selector in '' 25+1-test; do
    expected=$XDG_DATA_HOME/jvm/default
    [ -z "$selector" ] || expected=$XDG_DATA_HOME/jvm/jdks/25+1-test
    if [ -z "$selector" ]; then
        bash "$ROOT/jvm" home > "$TEMP/home.out" 2> "$TEMP/home.err"
        bash "$ROOT/jvm" env > "$TEMP/env.out" 2> "$TEMP/env.err"
    else
        bash "$ROOT/jvm" home "$selector" > "$TEMP/home.out" 2> "$TEMP/home.err"
        bash "$ROOT/jvm" env "$selector" > "$TEMP/env.out" 2> "$TEMP/env.err"
    fi
    [ ! -s "$TEMP/home.err" ] && [ ! -s "$TEMP/env.err" ]
    [ "$(< "$TEMP/home.out")" = "$(cygpath -m "$expected")" ]
    bash -c '
        set -eu
        original=$PATH
        code=$(< "$1")
        eval "$code"
        [ "$JAVA_HOME" = "$2" ] && [ "$PATH" = "$3/bin:$original" ]
    ' bash "$TEMP/env.out" "$(cygpath -m "$expected")" "$(cygpath -u "$expected")"
done
bash "$ROOT/jvm" uninstall 25
[ "$XDG_DATA_HOME/jvm/default" -ef "$XDG_DATA_HOME/jvm/jdks/21+1-test" ]
bash "$ROOT/jvm" uninstall 21
[ ! -L "$XDG_DATA_HOME/jvm/default" ] && [ ! -e "$XDG_DATA_HOME/jvm/default" ]
echo 'ok - native junction creation, replacement, executable traversal, home/env conversion and uninstall fallback'
