#!/usr/bin/env bash
# Optional native Windows junction smoke: isolated storage, no downloads/JDK use.
set -eu
BASH_BIN=$BASH
ROOT=$(cd "$(dirname "$0")/.." && pwd)
case "$(uname -s)" in CYGWIN*|MSYS*|MINGW*) ;; *) echo 'Windows Bash required' >&2; exit 1 ;; esac
system_directory=$(cygpath -u -S)
native_cmd=$system_directory/cmd.exe
[ -f "$native_cmd" ] || { echo "Native cmd.exe not found: $native_cmd" >&2; exit 1; }
# Cygwin need not inherit System32 on PATH. The manager also needs cmd.exe
# for junction creation; discover it without relying on environment-name case.
export PATH="$PATH:$system_directory"
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/jvm-native-default.XXXXXXXX")
cleanup() {
    for link in default 21 25; do
        [ ! -L "$XDG_DATA_HOME/jvm/jdks/$link" ] || rm -- "$XDG_DATA_HOME/jvm/jdks/$link"
    done
    rm -rf -- "$TEMP"
}
mkdir -p "$TEMP/project with spaces"
cd "$TEMP/project with spaces" || exit 1
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
    cp "$native_cmd" "$home/bin/java.exe"
    cp "$native_cmd" "$home/bin/javac.exe"
    printf 'jvm-manifest-v1\nga\twindows\t%s\tjdk\thotspot\tvendor\ttest\t%s+99\t%s+1\tzip\thttps://invalid.test/jdk\tjdk.zip\t0\t%064d\t[]\n\n' "$arch" "$major" "$major" 0 > "$home/.jvm-manifest"
done
"$BASH_BIN" "$ROOT/jvm" i -d 21+1-test
[ -L "$XDG_DATA_HOME/jvm/jdks/default" ]
[ -L "$XDG_DATA_HOME/jvm/jdks/21" ]
"$BASH_BIN" "$ROOT/jvm" install 25+1-test
"$BASH_BIN" "$ROOT/jvm" d 25
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
        "$BASH_BIN" "$ROOT/jvm" home > "$TEMP/home.out" 2> "$TEMP/home.err"
        "$BASH_BIN" "$ROOT/jvm" env > "$TEMP/env.out" 2> "$TEMP/env.err"
    else
        "$BASH_BIN" "$ROOT/jvm" h "$selector" > "$TEMP/home.out" 2> "$TEMP/home.err"
        "$BASH_BIN" "$ROOT/jvm" e "$selector" > "$TEMP/env.out" 2> "$TEMP/env.err"
    fi
    [ ! -s "$TEMP/home.err" ] && [ ! -s "$TEMP/env.err" ]
    [ "$(< "$TEMP/home.out")" = "$expected" ]
    "$BASH_BIN" -c '
        set -eu
        original=$PATH
        code=$(< "$1")
        eval "$code"
        [ "$JAVA_HOME" = "$2" ] && [ "$PATH" = "$3/bin:$original" ]
    ' bash "$TEMP/env.out" "$(cygpath -m "$expected")" "$(cygpath -u "$expected")"
done
# Configured bare majors retain stable junction output, while exec uses the
# physical installation. Selectorless selection also preserves the existing default.
printf 'java=21\ndistro=unused\n' > .jvmrc
[ "$("$BASH_BIN" "$ROOT/jvm" h)" = "$base/jdks/21" ]
[ "$("$BASH_BIN" "$ROOT/jvm" x _ "$BASH_BIN" -c 'printf "%s" "$JAVA_HOME"')" = "$(cygpath -m "$base/jdks/21+1-test")" ]
rm .jvmrc
[ "$("$BASH_BIN" "$ROOT/jvm" h)" = "$base/jdks/default" ]
"$BASH_BIN" "$ROOT/jvm" uninstall 25
[ "$XDG_DATA_HOME/jvm/jdks/default" -ef "$XDG_DATA_HOME/jvm/jdks/21+1-test" ]
[ ! -L "$XDG_DATA_HOME/jvm/jdks/25" ]
"$BASH_BIN" "$ROOT/jvm" uninstall 21
[ ! -L "$XDG_DATA_HOME/jvm/jdks/default" ] && [ ! -e "$XDG_DATA_HOME/jvm/jdks/default" ]
[ ! -L "$XDG_DATA_HOME/jvm/jdks/21" ]
echo 'ok - native junction creation, replacement, executable traversal, home/env range conversion and uninstall fallback'
