#!/usr/bin/env bash
# Offline home/env contract checks; platform adapters are simulated.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BASH_BIN=$BASH
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/jvm-home-env.XXXXXXXX")
trap 'rm -rf -- "$TEMP"' EXIT
trap 'exit 1' HUP INT TERM
export MSYS=winsymlinks:nativestrict
export HOME="$TEMP/home" XDG_DATA_HOME="$TEMP/data spaces '\$dollar\`tick & (stuff)!"
export XDG_CACHE_HOME="$TEMP/cache" XDG_CONFIG_HOME="$TEMP/config" XDG_STATE_HOME="$TEMP/state"
mkdir -p "$HOME" "$TEMP/tools"
export TEST_SYSTEM=Linux TEST_CONVERT_FAIL=0
for tool in awk readlink; do
    path=$(command -v "$tool")
    printf '#!%s\nexec "%s" "$@"\n' "$BASH_BIN" "$path" > "$TEMP/tools/$tool"
done
printf '#!%s\ncase "$1" in -s) echo "$TEST_SYSTEM" ;; -m) echo x86_64 ;; esac\n' "$BASH_BIN" > "$TEMP/tools/uname"
printf '#!%s\necho "GNU libc"\n' "$BASH_BIN" > "$TEMP/tools/ldd"
printf '#!%s\n[ "$TEST_CONVERT_FAIL" = 0 ] || exit 1\ncase "$1" in -m) printf "C:%%s\\n" "$2" ;; -u) printf "%%s\\n" "${2#C:}" ;; esac\n' "$BASH_BIN" > "$TEMP/tools/cygpath"
chmod +x "$TEMP/tools/"*
fail() { echo "FAIL: $*" >&2; cat "$TEMP/err" >&2; exit 1; }
run() {
    local expected=$1 actual=0
    shift
    if [ -d "$XDG_DATA_HOME" ]; then tar -cf "$TEMP/before" -C "$XDG_DATA_HOME" .; fi
    PATH="$TEMP/tools" "$BASH_BIN" "$ROOT/jvm" "$@" > "$TEMP/out" 2> "$TEMP/err" || actual=$?
    [ "$actual" = "$expected" ] || fail "exit $actual expected $expected: $*"
    if [ "$expected" = 0 ]; then [ ! -s "$TEMP/err" ] || fail "success stderr: $*"
    else [ ! -s "$TEMP/out" ] && [ -s "$TEMP/err" ] || fail "failure output: $*"; fi
    if [ -d "$XDG_DATA_HOME" ]; then
        tar -cf "$TEMP/after" -C "$XDG_DATA_HOME" .
        cmp "$TEMP/before" "$TEMP/after" || fail "managed state changed: $*"
    fi
    [ ! -e "$XDG_CACHE_HOME" ] && [ ! -e "$XDG_CONFIG_HOME" ] && [ ! -e "$XDG_STATE_HOME" ] || fail 'unrelated storage accessed'
}
exact() { printf '%s\n' "$1" > "$TEMP/expected"; cmp "$TEMP/expected" "$TEMP/out" || fail 'unexpected exact output'; }
diagnostic() { [[ $(< "$TEMP/err") = *"$1"* ]] || fail "missing diagnostic: $1"; }
make_jdk() {
    local version=$1 distro=$2 os=${3:-linux} home
    home=$XDG_DATA_HOME/jvm/jdks/$version-$distro
    mkdir -p "$home"
    tar -xzf "$ROOT/tests/fixtures/archives/jdk.tar.gz" -C "$home" --strip-components=1
    printf 'jvm-install-v2\t%s-%s\t%s\t%s\thotspot\t%s\tx86_64\t.\thttps://invalid.test/jdk\t%064d\ttar.gz\t0\n' "$version" "$distro" "$distro" "$version" "$os" 0 > "$home/.jvm-manifest"
}
check_env() {
    local java=$1 bin=$2 selector=${3:-} usage='jvm env'
    [ -z "$selector" ] || usage="$usage $selector"
    printf '# Use: eval "$(%s)"\n' "$usage" > "$TEMP/comment"
    head -1 "$TEMP/out" > "$TEMP/first"
    cmp "$TEMP/comment" "$TEMP/first" || fail 'usage comment'
    [ "$(wc -l < "$TEMP/out")" -eq 3 ] || fail 'env must have three lines'
    [[ $(sed -n '2p' "$TEMP/out") = "export JAVA_HOME='"* ]] || fail 'JAVA_HOME statement'
    [[ $(sed -n '3p' "$TEMP/out") = "export PATH='"*':"$PATH"' ]] || fail 'PATH statement'
    # Only this isolated child evaluates the generated shell code.
    PATH='/child/first:/child/second with spaces' "$BASH_BIN" -c '
        set -eu
        original=$PATH
        code=$(< "$1")
        eval "$code"
        [ "$JAVA_HOME" = "$2" ] && [ "$PATH" = "$3:$original" ]
    ' bash "$TEMP/out" "$java" "$bin" || fail 'evaluated environment differs'
}
for command in home env; do
    run 1 "$command"; diagnostic 'default JDK is missing or unusable'
    run 1 "$command" 21; diagnostic 'No JDK found matching: 21'
    for selector in '' 0 01 temurin '21+' '21..25' '$(touch bad)' --bad; do run 2 "$command" "$selector"; done
    run 2 "$command" 21 extra
    run 2 "$command" --help extra
    run 0 "$command" --help
    PATH="$TEMP/tools" "$BASH_BIN" "$ROOT/jvm" --help > "$TEMP/help"
    cmp "$TEMP/help" "$TEMP/out" || fail 'subcommand help differs'
done
make_jdk 21+1 temurin
make_jdk 17+2 graalvm-community
make_jdk 1.8.0_482-b08 legacy
base=$(cd "$XDG_DATA_HOME/jvm" && pwd -P)
ln -s "$base/jdks/21+1-temurin" "$base/default"
for selector in 21+1-temurin 21 temurin-21 graalvm-community-17 8; do
    case "$selector" in graalvm*) expected=$base/jdks/17+2-graalvm-community ;; 8) expected=$base/jdks/1.8.0_482-b08-legacy ;; *) expected=$base/jdks/21+1-temurin ;; esac
    run 0 home "$selector"; exact "$expected"
    run 0 env "$selector"; check_env "$expected" "$expected/bin" "$selector"
done
run 0 home; exact "$base/default"
run 0 env; check_env "$base/default" "$base/default/bin"
make_jdk 21+9 other
for command in home env; do
    run 1 "$command" 21; diagnostic 'Multiple JDKs match, try again using one of the following IDs:'
    diagnostic '21+1-temurin'; diagnostic '21+9-other'
    run 1 "$command" temurin-99; diagnostic 'No JDK found matching: temurin-99'
    run 0 "$command" 21+1-temurin
    rm "$base/default"
    run 1 "$command"; diagnostic 'default JDK is missing or unusable'
    # Explicit selection does not need a usable default.
    ln -s "$base/jdks/99+1-missing" "$base/default"
    run 1 "$command"; diagnostic 'default JDK is missing or unusable'
    run 0 "$command" temurin-21
    rm "$base/default"
    ln -s "$HOME" "$base/default"
    run 1 "$command"; diagnostic 'default JDK is missing or unusable'
    rm "$base/default"; mkdir "$base/default"
    run 1 "$command"; diagnostic 'default JDK is missing or unusable'
    rmdir "$base/default"; ln -s "$base/jdks/21+1-temurin" "$base/default"
    mv "$base/jdks/21+1-temurin/bin/javac" "$TEMP/javac"
    run 1 "$command"; diagnostic 'default JDK is missing or unusable'
    mv "$TEMP/javac" "$base/jdks/21+1-temurin/bin/javac"
done
# Simulated Windows conversion uses a drive colon for JAVA_HOME, never PATH.
export TEST_SYSTEM=MINGW64_NT-10.0
make_jdk 25+1 windows-test windows
rm "$base/default"; ln -s "$base/jdks/25+1-windows-test" "$base/default"
for selector in '' windows-test-25; do
    expected=$base/default
    [ -z "$selector" ] || expected=$base/jdks/25+1-windows-test
    if [ -z "$selector" ]; then run 0 home; else run 0 home "$selector"; fi
    exact "C:$expected"
    if [ -z "$selector" ]; then run 0 env; else run 0 env "$selector"; fi
    check_env "C:$expected" "$expected/bin" "$selector"
done
# A usable home still cannot be represented in the promised single-line format.
saved_data=$XDG_DATA_HOME
export XDG_DATA_HOME="$TEMP/line"$'\n'"break"
make_jdk 25+1 windows-test windows
for command in home env; do
    run 1 "$command" windows-test-25; diagnostic 'single-line path'
done
export XDG_DATA_HOME=$saved_data
export TEST_CONVERT_FAIL=1
run 1 env; diagnostic 'cannot convert JDK home path'
run 1 home; diagnostic 'cannot convert JDK home path'
echo 'PASS: offline home/env selection, quoting, evaluation, failures and state preservation (Windows simulated)'
