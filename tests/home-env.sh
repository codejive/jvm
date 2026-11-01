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
    PATH="${TEST_PATH-$TEMP/tools}" "$BASH_BIN" "$ROOT/jvm" "$@" > "$TEMP/out" 2> "$TEMP/err" || actual=$?
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
    local major=${version#1.}
    major=${major%%[^0-9]*}
    home=$XDG_DATA_HOME/jvm/jdks/$version-$distro
    [[ $version = "$major"[!0-9]* ]] || home=$XDG_DATA_HOME/jvm/jdks/$major-$version-$distro
    mkdir -p "$home"
    tar -xzf "$ROOT/tests/fixtures/archives/jdk.tar.gz" -C "$home" --strip-components=1
    printf 'jvm-manifest-v1\nga\t%s\tx86_64\tjdk\thotspot\tvendor\t%s\t%s\t%s\ttar.gz\thttps://invalid.test/jdk\tjdk.tar.gz\t0\t%064d\t[]\n\n' "$os" "$distro" "$version" "$version" 0 > "$home/.jvm-manifest"
}
check_env() {
    local java=$1 bin=$2 selector=${3:-} omit=${4:-0} usage='jvm env' lines=3
    [ -z "$selector" ] || usage="$usage $selector"
    printf '# Use: eval "$(%s)"\n' "$usage" > "$TEMP/comment"
    head -1 "$TEMP/out" > "$TEMP/first"
    cmp "$TEMP/comment" "$TEMP/first" || fail 'usage comment'
    [ "$omit" = 0 ] || lines=2
    [ "$(wc -l < "$TEMP/out")" -eq "$lines" ] || fail 'unexpected env line count'
    [[ $(sed -n '2p' "$TEMP/out") = "export JAVA_HOME='"* ]] || fail 'JAVA_HOME statement'
    if [ "$omit" = 0 ]; then
        [[ $(sed -n '3p' "$TEMP/out") = "export PATH='"*':"$PATH"' ]] || fail 'PATH statement'
    fi
    # Only this isolated child evaluates the generated shell code.
    PATH='/child/first:/child/second with spaces' "$BASH_BIN" -c '
        set -eu
        [ "$4" = 0 ] || PATH="/child/first:$3:/child/second with spaces"
        original=$PATH
        code=$(< "$1")
        eval "$code"
        [ "$JAVA_HOME" = "$2" ] || exit 1
        if [ "$4" = 0 ]; then [ "$PATH" = "$3:$original" ]; else [ "$PATH" = "$original" ]; fi
    ' bash "$TEMP/out" "$java" "$bin" "$omit" || fail 'evaluated environment differs'
}
for command in home env; do
    run 1 "$command"; diagnostic 'No JDK currently set as the default'
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
run 0 default; exact 'No JDK currently set as the default'
run 0 default -v 21; exact 'No JDK currently set as the default for version 21'
for command in home env; do
    run 1 "$command"; diagnostic 'No JDK currently set as the default'
    run 0 "$command" 21
    if [ "$command" = home ]; then exact "$base/jdks/21+1-temurin"; else check_env "$base/jdks/21+1-temurin" "$base/jdks/21+1-temurin/bin" 21; fi
done
ln -s "$base/jdks/21+1-temurin" "$base/jdks/default"
ln -s "$base/jdks/21+1-temurin" "$base/jdks/21"
ln -s "$base/jdks/8-1.8.0_482-b08-legacy" "$base/jdks/8"
for selector in 21+1-temurin 21 temurin-21 graalvm-community-17 8; do
    case "$selector" in graalvm*) expected=$base/jdks/17+2-graalvm-community ;; 8|21) expected=$base/jdks/$selector ;; *) expected=$base/jdks/21+1-temurin ;; esac
    run 0 home "$selector"; exact "$expected"
    run 0 env "$selector"; check_env "$expected" "$expected/bin" "$selector"
done
run 0 home; exact "$base/jdks/default"
run 0 env; check_env "$base/jdks/default" "$base/jdks/default/bin"
# Match whole literal PATH entries, at any position, preserving their order.
bin=$base/jdks/default/bin
for TEST_PATH in "$bin:$TEMP/tools" "$TEMP/tools:$bin:/after" "$TEMP/tools:$bin" ":$TEMP/tools::$bin:"; do
    run 0 env; check_env "$base/jdks/default" "$bin" '' 1
    run 0 e -f; check_env "$base/jdks/default" "$bin" '-f'
done
for TEST_PATH in "$TEMP/tools:$bin-extra" "$TEMP/tools:/prefix$bin" "$TEMP/tools:$bin/"; do
    run 0 env; check_env "$base/jdks/default" "$bin"
done
unset TEST_PATH
bin=$base/jdks/21/bin
TEST_PATH="$TEMP/tools:$bin" run 0 env -i 21
check_env "$base/jdks/21" "$bin" '-i 21' 1
for args in '-f -i 21' '-i 21 -f' '21 -f -i'; do
    TEST_PATH="$TEMP/tools:$bin" run 0 e $args
    check_env "$base/jdks/21" "$bin" '-i -f 21'
done
for command in available list install uninstall default home a l i u d h; do
    run 2 "$command" -f; diagnostic 'unsupported flag'
done
run 2 env -f -f; diagnostic 'duplicate flag'
run 2 env -f -i; diagnostic 'Missing selector'
make_jdk 21+2 temurin
for command in home env; do
    run 1 "$command" temurin-21; diagnostic 'Multiple JDKs match'
done
rm -rf -- "$base/jdks/21+2-temurin"
make_jdk 21+9 other
for command in home env; do
    run 0 "$command" 21
    if [ "$command" = home ]; then exact "$base/jdks/21"; else check_env "$base/jdks/21" "$base/jdks/21/bin" 21; fi
    run 1 "$command" temurin-99; diagnostic 'No JDK found matching: temurin-99'
    run 0 "$command" 21+1-temurin
    rm "$base/jdks/default"
    run 1 "$command"; diagnostic 'No JDK currently set as the default'
    # Explicit selection does not need a usable default.
    ln -s "$base/jdks/99+1-missing" "$base/jdks/default"
    run 1 "$command"; diagnostic 'default JDK is missing or unusable'
    run 0 "$command" temurin-21
    rm "$base/jdks/default"
    ln -s "$HOME" "$base/jdks/default"
    run 1 "$command"; diagnostic 'default JDK is missing or unusable'
    rm "$base/jdks/default"; mkdir "$base/jdks/default"
    run 1 "$command"; diagnostic 'default JDK is missing or unusable'
    rmdir "$base/jdks/default"; ln -s "$base/jdks/21+1-temurin" "$base/jdks/default"
    mv "$base/jdks/21+1-temurin/bin/javac" "$TEMP/javac"
    run 1 "$command"; diagnostic 'default JDK is missing or unusable'
    mv "$TEMP/javac" "$base/jdks/21+1-temurin/bin/javac"
done
# Missing references fall back to inventory; existing invalid references fail.
rm "$base/jdks/21" "$base/jdks/8"
for command in home env; do
    run 1 "$command" 21; diagnostic 'Multiple JDKs match'; diagnostic '21+1-temurin'; diagnostic '21+9-other'
    run 0 "$command" 8
    if [ "$command" = home ]; then exact "$base/jdks/8-1.8.0_482-b08-legacy"; else check_env "$base/jdks/8-1.8.0_482-b08-legacy" "$base/jdks/8-1.8.0_482-b08-legacy/bin" 8; fi
done
printf 'unrelated\n' > "$base/jdks/21"
for command in home env; do
    run 1 "$command" 21; diagnostic 'not a managed link'
done
rm "$base/jdks/21"
ln -s "$base/jdks/99+1-missing" "$base/jdks/21"
for command in home env; do
    run 1 "$command" 21; diagnostic 'default JDK for version 21 is unavailable'
    run 1 "$command" -i 21; diagnostic 'default JDK for version 21 is unavailable'
done
rm "$base/jdks/21"
ln -s "$base/jdks/17+2-graalvm-community" "$base/jdks/21"
for command in home env; do
    run 1 "$command" 21; diagnostic 'expected 21'
done
rm "$base/jdks/21"
ln -s "$base/jdks/21+1-temurin" "$base/jdks/21"
# Fail if the resolver scans another installation: a major reference is sufficient.
real_awk=$(command -v awk)
mv "$TEMP/tools/awk" "$TEMP/awk"
printf '#!%s\nfor arg in "$@"; do case "$arg" in */17+2-graalvm-community/.jvm-manifest) exit 2 ;; esac; done\nexec "%s" "$@"\n' "$BASH_BIN" "$real_awk" > "$TEMP/tools/awk"
chmod +x "$TEMP/tools/awk"
for command in home env; do
    run 0 "$command" 21
    if [ "$command" = home ]; then exact "$base/jdks/21"; else check_env "$base/jdks/21" "$base/jdks/21/bin" 21; fi
    run 0 "$command" -i 21
    if [ "$command" = home ]; then exact "$base/jdks/21"; else
        check_env "$base/jdks/21" "$base/jdks/21/bin" '-i 21'
    fi
done
mv "$TEMP/awk" "$TEMP/tools/awk"
# Simulated Windows conversion uses a drive colon for JAVA_HOME, never PATH.
export TEST_SYSTEM=MINGW64_NT-10.0
make_jdk 25+1 windows-test windows
rm "$base/jdks/default"; ln -s "$base/jdks/25+1-windows-test" "$base/jdks/default"
for selector in '' windows-test-25; do
    expected=$base/jdks/default
    [ -z "$selector" ] || expected=$base/jdks/25+1-windows-test
    if [ -z "$selector" ]; then run 0 home; else run 0 home "$selector"; fi
    exact "$expected"
    if [ -z "$selector" ]; then run 0 env; else run 0 env "$selector"; fi
    check_env "C:$expected" "$expected/bin" "$selector"
    TEST_PATH="$TEMP/tools:$expected/bin" run 0 env ${selector:+"$selector"}
    check_env "C:$expected" "$expected/bin" "$selector" 1
    TEST_PATH="$TEMP/tools:$expected/bin" run 0 env -f ${selector:+"$selector"}
    check_env "C:$expected" "$expected/bin" "-f${selector:+ $selector}"
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
run 0 home; exact "$base/jdks/default"
mv "$TEMP/tools/cygpath" "$TEMP/cygpath"
run 0 home windows-test-25; exact "$base/jdks/25+1-windows-test"
mv "$TEMP/cygpath" "$TEMP/tools/cygpath"
echo 'PASS: offline home/env selection, quoting, evaluation, failures and state preservation (Windows simulated)'
