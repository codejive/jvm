#!/usr/bin/env bash
# Optional native Windows junction smoke: isolated storage, no downloads/JDK use.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
case "$(uname -s)" in CYGWIN*|MSYS*|MINGW*) ;; *) echo 'Windows Bash required' >&2; exit 1 ;; esac
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/jvm-native-default.XXXXXXXX")
cleanup() {
    for link in default 21 25; do
        [ ! -L "$XDG_DATA_HOME/jvm/jdks/$link" ] || rm -- "$XDG_DATA_HOME/jvm/jdks/$link"
    done
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
    printf 'jvm-manifest-v1\nga\twindows\t%s\tjdk\thotspot\tvendor\ttest\t%s+99\t%s+1\tzip\thttps://invalid.test/jdk\tjdk.zip\t0\t%064d\t[]\n\n' "$arch" "$major" "$major" 0 > "$home/.jvm-manifest"
done
bash "$ROOT/jvm" i -d 21+1-test
[ -L "$XDG_DATA_HOME/jvm/jdks/default" ]
[ -L "$XDG_DATA_HOME/jvm/jdks/21" ]
bash "$ROOT/jvm" install 25+1-test
bash "$ROOT/jvm" d -i 25
[ "$XDG_DATA_HOME/jvm/jdks/default" -ef "$XDG_DATA_HOME/jvm/jdks/25+1-test" ]
[ "$XDG_DATA_HOME/jvm/jdks/21" -ef "$XDG_DATA_HOME/jvm/jdks/21+1-test" ]
[ "$XDG_DATA_HOME/jvm/jdks/25" -ef "$XDG_DATA_HOME/jvm/jdks/25+1-test" ]
MSYS2_ARG_CONV_EXCL='*' "$XDG_DATA_HOME/jvm/jdks/default/bin/java.exe" /d /c exit 0
# Native path conversion through the stable junction and explicit inventory home.
base=$(cd "$XDG_DATA_HOME/jvm" && pwd -P)
for selector in '' 25+1-test 25 21+ 21..25; do
    expected=$base/jdks/default
    [ -z "$selector" ] || expected=$base/jdks/25+1-test
    [ "$selector" != 25 ] || expected=$base/jdks/25
    if [ -z "$selector" ]; then
        bash "$ROOT/jvm" home > "$TEMP/home.out" 2> "$TEMP/home.err"
        bash "$ROOT/jvm" env > "$TEMP/env.out" 2> "$TEMP/env.err"
    else
        bash "$ROOT/jvm" h -i "$selector" > "$TEMP/home.out" 2> "$TEMP/home.err"
        bash "$ROOT/jvm" e "$selector" -i > "$TEMP/env.out" 2> "$TEMP/env.err"
    fi
    [ ! -s "$TEMP/home.err" ] && [ ! -s "$TEMP/env.err" ]
    [ "$(< "$TEMP/home.out")" = "$expected" ]
    bash -c '
        set -eu
        original=$PATH
        code=$(< "$1")
        eval "$code"
        [ "$JAVA_HOME" = "$2" ] && [ "$PATH" = "$3/bin:$original" ]
    ' bash "$TEMP/env.out" "$(cygpath -m "$expected")" "$(cygpath -u "$expected")"
done
bash "$ROOT/jvm" uninstall 25
[ "$XDG_DATA_HOME/jvm/jdks/default" -ef "$XDG_DATA_HOME/jvm/jdks/21+1-test" ]
[ ! -L "$XDG_DATA_HOME/jvm/jdks/25" ]
bash "$ROOT/jvm" uninstall 21
[ ! -L "$XDG_DATA_HOME/jvm/jdks/default" ] && [ ! -e "$XDG_DATA_HOME/jvm/jdks/default" ]
[ ! -L "$XDG_DATA_HOME/jvm/jdks/21" ]
echo 'ok - native junction creation, replacement, executable traversal, home/env range conversion and uninstall fallback'
