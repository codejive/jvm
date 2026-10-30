#!/usr/bin/env bash
# Offline integration checks using real archive tools and inert tiny JDK files.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BASH_BIN=${BASH:-bash}
ORIGINAL_PATH=$PATH
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/jvm-install-tests.XXXXXXXX") || exit 1
cleanup() {
    if [ -n "${TEST_PUBLISH_GATE:-}" ]; then
        : > "$TEST_PUBLISH_GATE/first.release"
        : > "$TEST_PUBLISH_GATE/second.release"
    fi
    for pid in "${first:-}" "${second:-}"; do
        [ -z "$pid" ] || { kill -TERM "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; }
    done
    rm -rf -- "$TEMP"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
export HOME="$TEMP/home with spaces" XDG_DATA_HOME="$TEMP/data with spaces"
export XDG_CACHE_HOME="$TEMP/cache with spaces" XDG_CONFIG_HOME="$TEMP/config" XDG_STATE_HOME="$TEMP/state"
mkdir -p "$HOME" "$TEMP/bin"
TOOLS=$TEMP/bin
for tool in mkdir mktemp rm rmdir sed awk cat mv date cp sleep wc find tar gzip unzip sha256sum openssl; do
    path=$(command -v "$tool") || continue
    printf '#!%s\nexec "%s" "$@"\n' "$BASH_BIN" "$path" > "$TOOLS/$tool"
    chmod +x "$TOOLS/$tool" || exit 1
done
export TEST_SYSTEM=Linux TEST_MACHINE=x86_64 TEST_OS=linux
export TEST_LOG="$TEMP/requests" TEST_FIXTURE="$TEMP/index.tsv"
export TEST_ARCHIVE="$ROOT/tests/fixtures/archives/jdk.tar.gz"
export TEST_ARTIFACT_STATUS=200 TEST_DELAY=0
export TEST_PUBLISH_GATE= TEST_PUBLISH_FAIL=0 TEST_REAL_MV TEST_REAL_RM
export TEST_REMOVE_FAIL=0 TEST_REMOVE_DELETE_FAIL=0 TEST_REMOVE_LOG="$TEMP/removals"
TEST_REAL_MV=$(command -v mv)
TEST_REAL_RM=$(command -v rm)
for tool in uname ldd curl wget mv rm; do
    printf '#!%s\n' "$BASH_BIN" > "$TOOLS/$tool"
    case "$tool" in
        uname) printf '%s\n' 'case "$1" in -s) echo "$TEST_SYSTEM" ;; -m) echo "$TEST_MACHINE" ;; esac' >> "$TOOLS/$tool" ;;
        ldd) printf '%s\n' 'echo "ldd (GNU libc)"' >> "$TOOLS/$tool" ;;
        rm) cat >> "$TOOLS/$tool" <<'EOF'
for path in "$@"; do
    case "$path" in "$XDG_DATA_HOME/jvm/tmp/remove-"*)
        for home in "$path"/*; do
            [ ! -e "$XDG_DATA_HOME/jvm/jdks/${home##*/}" ] || exit 99
        done
        printf '%s\n' "$path" >> "$TEST_REMOVE_LOG"
        [ "$TEST_REMOVE_DELETE_FAIL" != 1 ] || exit 1 ;;
    esac
done
case "$1" in
    -rf|-fr)
        for path in "$@"; do
            case "$path" in "$XDG_DATA_HOME/jvm/jdks/"*) echo 'recursive cleanup inside jdks is forbidden in this test' >&2; exit 1 ;; esac
        done ;;
esac
exec "$TEST_REAL_RM" "$@"
EOF
        ;;
        mv) cat >> "$TOOLS/$tool" <<'EOF'
if [ "$#" -eq 2 ]; then
    case "$2" in "$XDG_DATA_HOME/jvm/tmp/remove-"*/)
        [ "$TEST_REMOVE_FAIL" != 1 ] || exit 1
        [ -d "$2" ] && [ ! -e "$2/${1##*/}" ] || exit 99
        printf '%s\n' "$1 -> $2" >> "$TEST_REMOVE_LOG" ;;
    esac
fi
case "$1" in
    "$XDG_DATA_HOME/jvm/jdks/"*/jdk-*)
        if [ "$#" -eq 2 ] && [[ $2 = "$XDG_DATA_HOME/jvm/tmp/jdk-"* ]]; then
            "$TEST_REAL_MV" "$@"; status=$?
            if [ "$status" -eq 0 ] && [ -n "$TEST_PUBLISH_GATE" ]; then
                printf '%s\n' "$TEST_PUBLISH_ROLE" >> "$TEST_PUBLISH_GATE/reclaimed-copies"
            fi
            exit "$status"
        fi ;;
    */jvm/tmp/jdk-*/*)
        if [ "$#" -eq 2 ] && [ "${2%/*}" = "$XDG_DATA_HOME/jvm/jdks" ]; then
            if [ "$TEST_PUBLISH_FAIL" = 1 ]; then echo 'simulated publish failure' >&2; exit 1; fi
            if [ -n "$TEST_PUBLISH_GATE" ]; then
                role=${TEST_PUBLISH_ROLE:-}
                [ -n "$role" ] || exit 99
                printf '%s\n' "$1" > "$TEST_PUBLISH_GATE/$role.ready"
                while [ ! -e "$TEST_PUBLISH_GATE/$role.release" ]; do sleep 0.05; done
                "$TEST_REAL_MV" "$@"; status=$?
                if [ -d "$2/${1##*/}" ]; then printf '%s\n' "$role" >> "$TEST_PUBLISH_GATE/nested-copies"; fi
                exit "$status"
            fi
        fi ;;
esac
exec "$TEST_REAL_MV" "$@"
EOF
        ;;
        curl|wget) cat >> "$TOOLS/$tool" <<'EOF'
if [ "${1:-}" = --help ]; then echo '--https-only --header'; exit 0; fi
adapter=${0##*/}; output= headers= url=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --output|-O) output=$2; shift ;;
        --dump-header) headers=$2; shift ;;
        https://*) url=$1 ;;
    esac
    shift
done
printf '%s\n' "$url" >> "$TEST_LOG"
status=200; body=$TEST_FIXTURE
case "$url" in
    https://artifacts.invalid/*)
        body=$TEST_ARCHIVE; status=$TEST_ARTIFACT_STATUS
        if [ "$TEST_DELAY" != 0 ]; then
            : > "$TEST_LOG.started"
            sleep "$TEST_DELAY"
        fi ;;
esac
if [ "$adapter" = curl ]; then
    printf 'HTTP/1.1 %s Status\r\n' "$status" > "$headers"
    printf '%s' "$status"
else printf '  HTTP/1.1 %s Status\r\n' "$status" >&2; fi
case "$status" in
    200) cat "$body" > "$output" ;;
    partial) cat "$body" > "$output"; exit 7 ;;
    *) exit 7 ;;
esac
EOF
        ;;
    esac
    chmod +x "$TOOLS/$tool"
done
export PATH=$TOOLS
passed=0
fail() { printf 'FAIL: %s\n' "$*" >&2; cat "$TEMP/err" >&2; exit 1; }
check() { passed=$((passed+1)); printf 'ok %s - %s\n' "$passed" "$*"; }
run() {
    local expected=$1 actual
    shift
    "$BASH_BIN" "$ROOT/jvm" "$@" > "$TEMP/out" 2> "$TEMP/err"; actual=$?
    [ "$expected" -eq "$actual" ] || fail "exit $actual, expected $expected: $*"
    if [ "$expected" -ne 0 ]; then [ ! -s "$TEMP/out" ] || fail 'partial command output on failure'; fi
}
contains() { [[ $(< "$TEMP/out") = *"$1"* ]] || fail "missing output: $1"; }
diagnostic() { [[ $(< "$TEMP/err") = *"$1"* ]] || fail "missing diagnostic: $1"; }
reset() { rm -rf -- "$XDG_DATA_HOME/jvm" "$XDG_CACHE_HOME/jvm"; rm -f "$TEST_LOG" "$TEST_LOG.started"; }
index() { printf 'trusted header\n' > "$TEST_FIXTURE"; rm -rf -- "$XDG_CACHE_HOME/jvm"; }
row() {
    local version=$1 distro=$2 format=${3:-tar.gz} archive=${4:-$TEST_ARCHIVE} sha bytes
    sha=$(sha256sum "$archive"); sha=${sha%% *}
    bytes=$(wc -c < "$archive"); bytes=${bytes//[[:space:]]/}
    printf 'ga\t%s\tx86_64\tjdk\topenj9\tvendor\t%s\t99+1\t%s\t%s\thttps://artifacts.invalid/%s\tjdk.%s\t%s\t%s\t[]\n' "$TEST_OS" "$distro" "$version" "$format" "$format" "$format" "$bytes" "$sha" >> "$TEST_FIXTURE"
}
count_downloads() { awk '/https:\/\/artifacts.invalid/ {n++} END {print n+0}' "$TEST_LOG"; }

uninstall_checks() {
    reset; index
    run 2 uninstall; run 2 uninstall ''; run 2 uninstall 21 extra
    run 2 uninstall ../21; run 2 uninstall vendor
    run 1 uninstall 21; diagnostic 'No JDK found matching: 21'
    [ ! -e "$XDG_DATA_HOME/jvm" ] || fail 'unmatched removal created storage'
    row 21+1 temurin; row 21+2 temurin; row 21+1 other-vendor
    row 1.8.0_99-b09 old-vendor
    for id in 21+1-temurin 21+2-temurin 21+1-other-vendor 1.8.0_99-b09-old-vendor; do run 0 install "$id"; done
    printf 'keep\n' > "$XDG_DATA_HOME/jvm/default"
    mv "$TOOLS/curl" "$TEMP/curl"; mv "$TOOLS/wget" "$TEMP/wget"
    rm -rf -- "$XDG_CACHE_HOME/jvm"
    run 0 list 21; list_major=$(< "$TEMP/out"); contains '21+1-temurin'; contains '21+2-temurin'; contains '21+1-other-vendor'
    [[ $(< "$TEMP/out") != *old-vendor* ]] || fail 'major listing included another major'
    run 0 list temurin; list_temurin=$(< "$TEMP/out"); contains '21+1-temurin'; contains '21+2-temurin'
    [[ $(< "$TEMP/out") != *other-vendor* ]] || fail 'distro listing included another distro'
    run 0 list other-vendor-21; contains '21+1-other-vendor'
    [[ $(< "$TEMP/out") != *temurin* ]] || fail 'distro-major listing included another distro'
    run 0 list 21+1-temurin; contains '21+1-temurin'
    [[ $(< "$TEMP/out") != *21+2* ]] || fail 'exact ID listing included another ID'
    run 0 list 8; contains '1.8.0_99-b09-old-vendor'
    run 1 list 999; diagnostic 'No JDK found matching: 999'
    run 1 list missing-vendor; diagnostic 'No JDK found matching: missing-vendor'
    run 2 list ../21; run 2 list 01; run 2 list ''; run 2 list 21 extra
    [ ! -e "$XDG_CACHE_HOME/jvm" ] || fail 'filtered listing accessed cache'
    check 'offline list filters return all matching IDs, majors, distros and distro-majors'
    run 1 uninstall 21; diagnostic 'Multiple JDKs match, try again using one of the following IDs:'; diagnostic '21+1-temurin'; diagnostic '21+2-temurin'; diagnostic '21+1-other-vendor'
    [ "$(< "$TEMP/err")" = "Multiple JDKs match, try again using one of the following IDs:"$'\n'"$list_major" ] || fail 'major ambiguity table differs from list'
    run 1 uninstall temurin-21; diagnostic 'Multiple JDKs match, try again using one of the following IDs:'
    [ "$(< "$TEMP/err")" = "Multiple JDKs match, try again using one of the following IDs:"$'\n'"$list_temurin" ] || fail 'distro-major ambiguity table differs from list'
    [ ! -e "$TEST_REMOVE_LOG" ] || fail 'ambiguous removal moved a JDK'
    TEST_REMOVE_FAIL=1
    run 1 uninstall 21+1-temurin; diagnostic "couldn't uninstall 21+1-temurin"
    [[ $(< "$TEMP/err") != *'might be in use'* ]] || fail 'Windows hint on Linux'
    run 0 list; contains '21+1-temurin'
    TEST_REMOVE_FAIL=0
    run 0 uninstall 21+1-temurin; contains 'Successfully uninstalled 21+1-temurin'
    run 1 uninstall 21; diagnostic 'Multiple JDKs match, try again using one of the following IDs:'; diagnostic '21+2-temurin'; diagnostic '21+1-other-vendor'
    run 0 uninstall temurin-21; contains 'Successfully uninstalled 21+2-temurin'
    run 0 uninstall 8; contains 'Successfully uninstalled 1.8.0_99-b09-old-vendor'
    run 0 list; contains '21+1-other-vendor'
    [[ $(< "$TEMP/out") != *temurin* ]] || fail 'removed JDK still listed'
    TEST_REMOVE_DELETE_FAIL=1
    run 1 uninstall 21; diagnostic 'cannot remove uninstalled JDK staging directory'
    [ ! -e "$XDG_DATA_HOME/jvm/jdks/21+1-other-vendor" ] || fail 'deletion happened before detachment'
    found=0
    for stage in "$XDG_DATA_HOME/jvm/tmp"/remove-*; do
        [ -f "$stage/21+1-other-vendor/.jvm-manifest" ] || fail 'unexpected removal staging residue'
        found=$((found+1))
    done
    [ "$found" -eq 1 ] || fail 'removal reservations leaked'
    TEST_REMOVE_DELETE_FAIL=0
    run 1 uninstall 21; diagnostic 'No JDK found matching:'
    [ "$(< "$XDG_DATA_HOME/jvm/default")" = keep ] || fail 'uninstall changed default'
    [ ! -e "$XDG_CACHE_HOME/jvm" ] || fail 'uninstall accessed cache'
    mv "$TEMP/curl" "$TOOLS/curl"; mv "$TEMP/wget" "$TOOLS/wget"
    reset; TEST_SYSTEM=MINGW64_NT-10.0; TEST_OS=windows
    TEST_ARCHIVE=$ROOT/tests/fixtures/archives/windows.zip
    index; row 21+1 temurin zip
    run 0 install 21
    TEST_REMOVE_FAIL=1
    run 1 uninstall 21; diagnostic "couldn't uninstall 21+1-temurin (it might be in use)"
    run 0 list; contains '21+1-temurin'
    TEST_REMOVE_FAIL=0; run 0 uninstall temurin-21
    TEST_SYSTEM=Linux; TEST_OS=linux
    TEST_ARCHIVE=$ROOT/tests/fixtures/archives/jdk.tar.gz
    reset
    check 'offline uninstall selectors, ambiguity, move-before-delete, failures and simulated Windows in-use hint'
}

if [ "${1:-}" = --uninstall ]; then uninstall_checks; exit 0; fi

if [ "${1:-}" != --publication ]; then
run 0 list
[ "$(< "$TEMP/out")" = "No JDKs installed. Use 'install' to install one" ] || fail 'wrong empty inventory message'
[ ! -s "$TEMP/err" ] || fail 'empty listing wrote a diagnostic'
for selector in 21 temurin temurin-21 21+1-temurin; do
    run 0 list "$selector"
    [ "$(< "$TEMP/out")" = "No JDKs installed. Use 'install' to install one" ] || fail 'selector suppressed empty inventory message'
    [ ! -s "$TEMP/err" ] || fail 'empty selected listing wrote a diagnostic'
done
[ ! -e "$XDG_DATA_HOME" ] || fail 'empty listing created data storage'
run 2 install; run 2 list ''; run 2 list ../21; run 2 list extra extra
check 'empty offline inventory succeeds without creating storage; command usage'
uninstall_checks

index; row 21.0.2+9 vendor; run 0 install vendor-21; contains '21.0.2+9-vendor'
contains 'Successfully installed 21.0.2+9-vendor'; diagnostic 'Installing 21.0.2+9-vendor...'
[ -f "$XDG_DATA_HOME/jvm/jdks/21.0.2+9-vendor/lib/internal" ] || fail 'internal JDK link lost'
[ -f "$XDG_DATA_HOME/jvm/jdks/21.0.2+9-vendor/bin/java" ] || fail 'ID directory is not the JDK home'
[ -f "$XDG_DATA_HOME/jvm/jdks/21.0.2+9-vendor/.home-marker" ] || fail 'normalization lost dotfiles'
[ ! -e "$XDG_DATA_HOME/jvm/jdks/21.0.2+9-vendor/payload" ] || fail 'payload wrapper published'
before=$(count_downloads)
run 0 list; contains '21.0.2+9-vendor'; contains 'openj9'
run 0 install 21.0.2+9-vendor; contains 'Already installed 21.0.2+9-vendor'
run 0 install vendor-21
[ "$(count_downloads)" = "$before" ] || fail 'idempotent install redownloaded'
mv "$TOOLS/curl" "$TEMP/curl"; mv "$TOOLS/wget" "$TEMP/wget"
rm -rf -- "$XDG_CACHE_HOME/jvm"
run 0 list; contains '21.0.2+9-vendor'
run 0 install 21.0.2+9-vendor
mv "$TEMP/curl" "$TOOLS/curl"; mv "$TEMP/wget" "$TOOLS/wget"
check 'verified installation, internal links, durable offline listing and idempotent reinstall'

index; row 21.0.2+9 vendor; row 21.0.2+10 vendor; row 21.0.10+1 vendor
row 21.0.2+9 vendor zip "$ROOT/tests/fixtures/archives/jdk.zip"
run 1 install vendor-21; diagnostic 'Multiple JDKs match, try again using one of the following IDs:'; diagnostic '21.0.2+9-vendor'; diagnostic '21.0.10+1-vendor'
awk -F '\t+' 'NR==2 && ($1!="ID" || $2!="DISTRIBUTION" || $3!="VERSION" || $4!="JVM") {exit 1}
    END {if (NR!=5) exit 1}' "$TEMP/err" || fail 'install ambiguity must show a listing with each ID once'
run 0 install 21.0.2+10-vendor; contains '21.0.2+10-vendor'
index; row 1.8.0_99-b09 old-vendor; row 1.8.0_100-b02 old-vendor
run 1 install old-vendor-8; diagnostic 'Multiple JDKs match, try again using one of the following IDs:'
run 0 install 1.8.0_99-b09-old-vendor
index; row 17.0.20.b2 old-vendor; row 17.0.20.b10 old-vendor
run 1 install old-vendor-17; diagnostic 'Multiple JDKs match, try again using one of the following IDs:'
index; row 22.0.1+8-LTS vendor; row 22.0.1+9 vendor
run 1 install vendor-22; diagnostic 'Multiple JDKs match, try again using one of the following IDs:'
index; row 22.0.2+9 vendor; row 22.1.0.1-Final gluon-graalvm
row 22.3.3+java17 graalvm
run 0 install vendor-22; contains '22.0.2+9-vendor'
run 0 install graalvm-22; contains '22.3.3+java17-graalvm'
run 0 install gluon-graalvm-22; contains '22.1.0.1-Final-gluon-graalvm'
index; row 22.1.0.1-final lower-vendor
run 0 install lower-vendor-22; contains '22.1.0.1-final-lower-vendor'
index; row 25.0.1+7 vendor; row 25.0.1+7 other-vendor
run 0 install vendor-25; contains '25.0.1+7-vendor'
run 0 install 25.0.1+7-other-vendor
run 1 install vendor-999; diagnostic 'No JDK found matching:'
run 1 install 999+1-missing; diagnostic 'No JDK found matching:'
run 2 install vendor; diagnostic 'selector must'
index; row 26.0.1-weird vendor
run 0 install vendor-26; contains '26.0.1-weird-vendor'
run 0 install 26.0.1-weird-vendor
check 'IDs without version ordering, legacy/vendor labels, exact IDs, hyphenated distros and ambiguity'

index; row 22.0.2+9 temurin; row 22.3.3+java17 graalvm; row 22.1.0.1-Final gluon-graalvm
run 0 install 22; contains '22.0.2+9-temurin'
diagnostic 'Installing 22.0.2+9-temurin...'
before=$(count_downloads)
run 0 install temurin-22; contains '22.0.2+9-temurin'
[ "$(count_downloads)" = "$before" ] || fail 'bare major and temurin-major resolved differently'
run 0 install graalvm-22; contains '22.3.3+java17-graalvm'
run 0 available 22; contains '22.0.2+9-temurin'; contains '22.3.3+java17-graalvm'
index; row 23.0.2+9 other-vendor
run 1 install 23; diagnostic 'No JDK found matching:'
run 0 install other-vendor-23; contains '23.0.2+9-other-vendor'
index; row 22.0.2+9 temurin; row 22.0.2+10 temurin
run 1 install 22; diagnostic 'Multiple JDKs match, try again using one of the following IDs:'; diagnostic '22.0.2+9-temurin'; diagnostic '22.0.2+10-temurin'
check 'bare install majors use Temurin, explicit distro overrides, no vendor fallback; discovery remains broad'

# Captured upstream versions, not a hand-picked grammar. Keep every version
# unchanged while replacing network/artifact data with our inert local fixture.
index
sha=$(sha256sum "$TEST_ARCHIVE"); sha=${sha%% *}
bytes=$(wc -c < "$TEST_ARCHIVE"); bytes=${bytes//[[:space:]]/}
awk -F '\t' -v OFS='\t' -v sha="$sha" -v bytes="$bytes" '
    NR>1 {
        print "ga","linux","x86_64","jdk","hotspot","vendor",$1,$3,$2,"tar.gz","https://artifacts.invalid/tar.gz","jdk.tar.gz",bytes,sha,"[]"
        print "ga","linux","x86_64","jdk","hotspot","vendor","observed",$3,$2,"tar.gz","https://artifacts.invalid/tar.gz","jdk.tar.gz",bytes,sha,"[]"
    }
' "$ROOT/tests/fixtures/upstream-versions.tsv" >> "$TEST_FIXTURE"
before=$(count_downloads)
for major in 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27; do
    run 1 install "observed-$major"; diagnostic 'Multiple JDKs match, try again using one of the following IDs:'
    [[ $(< "$TEMP/err") != *'ordering'* ]] || fail 'vendor version syntax blocked selection'
done
run 1 install graalvm-22; diagnostic '22.3.3+java17-graalvm'
run 1 install gluon-graalvm-22; diagnostic '22.1.0.1-Final-gluon-graalvm'
[ "$(count_downloads)" = "$before" ] || fail 'ambiguous selector downloaded an arbitrary artifact'
run 0 install 22.3.3+java17-graalvm
run 0 install 21.0.11b1163.125-jetbrains
check 'all 235 captured upstream version forms filter without ranking; ambiguity never downloads an arbitrary ID'
if [ "${1:-}" = --selectors ]; then
    printf 'PASS: focused installation and selector checks (offline)\n'
    exit 0
fi

reset; index; row 21+1 vendor zip; row 21+1 vendor tar.gz
run 0 install vendor-21; contains '21+1-vendor'
[[ $(< "$TEST_LOG") = *'https://artifacts.invalid/tar.gz'* ]] || fail 'Linux did not prefer tar.gz'
reset; index; row 21+1 vendor tar.gz; row 21+1 vendor tar.gz; row 21+1 vendor zip
run 1 install vendor-21; diagnostic 'multiple artifact rows'
reset; index; row 21+1 vendor msi
run 1 install vendor-21; diagnostic 'No JDK found matching:'
run 1 available 21
TEST_ARCHIVE=$ROOT/tests/fixtures/archives/jdk.zip
reset; index; row 21+1 vendor zip
run 0 install vendor-21; contains '21+1-vendor'
check 'supported formats, Linux preference, opposite-format fallback, duplicate-row rejection and real ZIP extraction'

TEST_SYSTEM=MINGW64_NT-10.0; TEST_OS=windows
TEST_ARCHIVE=$ROOT/tests/fixtures/archives/windows.zip
reset; index; row 21+1 vendor tar.gz; row 21+1 vendor zip
run 0 install vendor-21; run 0 list; contains '21+1-vendor'
[ -f "$XDG_DATA_HOME/jvm/jdks/21+1-vendor/bin/java.exe" ] || fail 'Windows home not flattened'
[[ $(< "$TEST_LOG") = *'https://artifacts.invalid/zip'* ]] || fail 'Windows did not prefer ZIP'
TEST_ARCHIVE=$ROOT/tests/fixtures/archives/windows.tar.gz
reset; index; row 21+1 vendor tar.gz
run 0 install vendor-21
[[ $(< "$TEST_LOG") = *'https://artifacts.invalid/tar.gz'* ]] || fail 'Windows did not fall back to tar.gz'
for launcher in bat cmd bare; do
    TEST_ARCHIVE=$ROOT/tests/fixtures/archives/windows-$launcher.zip
    reset; index; row 21+1 vendor zip
    run 0 install vendor-21; run 0 list; contains '21+1-vendor'
    [ -d "$XDG_DATA_HOME/jvm/jdks/21+1-vendor/bin" ] || fail 'Windows launcher home not flattened'
done
TEST_SYSTEM=Darwin; TEST_OS=macosx; TEST_ARCHIVE=$ROOT/tests/fixtures/archives/macos.tar.gz
reset; index; row 21+1 vendor; row 21+1 vendor zip
run 0 install vendor-21; run 0 list; contains '21+1-vendor'
[ -f "$XDG_DATA_HOME/jvm/jdks/21+1-vendor/bin/java" ] || fail 'macOS Contents/Home not flattened'
[ ! -e "$XDG_DATA_HOME/jvm/jdks/21+1-vendor/Contents" ] || fail 'macOS bundle wrapper published'
[[ $(< "$TEST_LOG") = *'https://artifacts.invalid/tar.gz'* ]] || fail 'macOS did not prefer tar.gz'
TEST_SYSTEM=Linux; TEST_OS=linux; TEST_ARCHIVE=$ROOT/tests/fixtures/archives/jdk.tar.gz
check 'simulated Windows ZIP/.exe and macOS Contents/Home layouts'

for layout in rootless nested; do
    TEST_ARCHIVE=$ROOT/tests/fixtures/archives/$layout.tar.gz
    reset; index; row 21+1 vendor
    run 0 install vendor-21
    [ -f "$XDG_DATA_HOME/jvm/jdks/21+1-vendor/bin/java" ] || fail "$layout home not flattened"
    [ -f "$XDG_DATA_HOME/jvm/jdks/21+1-vendor/.home-marker" ] || fail "$layout lost dotfiles"
done
for bad_home in multiple-jdks home-escape manifest-collision; do
    TEST_ARCHIVE=$ROOT/tests/fixtures/archives/$bad_home.tar.gz
    reset; index; row 21+1 vendor
    run 1 install vendor-21
    [ ! -e "$XDG_DATA_HOME/jvm/jdks/21+1-vendor" ] || fail "published $bad_home"
done
TEST_ARCHIVE=$ROOT/tests/fixtures/archives/jdk.tar.gz
check 'rootless/nested home normalization; reject multiple homes, escaping home links and reserved manifests'

reset; index; row 21+1 vendor
sed 's/[0-9a-f]\{64\}/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/' "$TEST_FIXTURE" > "$TEMP/modified"
mv "$TEMP/modified" "$TEST_FIXTURE"
run 1 install vendor-21; diagnostic 'checksum mismatch'
[ ! -d "$XDG_DATA_HOME/jvm/jdks/21+1-vendor" ] || fail 'published bad checksum'
index; row 21+1 vendor
sed 's/[0-9a-f]\{64\}//' "$TEST_FIXTURE" > "$TEMP/modified"; mv "$TEMP/modified" "$TEST_FIXTURE"
before=$(count_downloads); run 1 install vendor-21; diagnostic 'SHA-256 is missing'
[ "$(count_downloads)" = "$before" ] || fail 'missing checksum downloaded artifact'
index; row 21+1 vendor
mv "$TOOLS/sha256sum" "$TEMP/sha256sum"; mv "$TOOLS/openssl" "$TEMP/openssl"
before=$(count_downloads); run 1 install vendor-21; diagnostic 'install sha256sum'
[ "$(count_downloads)" = "$before" ] || fail 'missing verifier downloaded artifact'
# Exercise shasum-compatible and openssl adapters without a hidden runtime.
printf '#!%s\n[ "$1" = -a ] && shift 2\nexec "%s" "$@"\n' "$BASH_BIN" "$(PATH=$ORIGINAL_PATH command -v sha256sum)" > "$TOOLS/shasum"
PATH=$ORIGINAL_PATH chmod +x "$TOOLS/shasum"
run 0 install vendor-21
rm -f "$TOOLS/shasum"; mv "$TEMP/openssl" "$TOOLS/openssl"
reset; index
sha=$("$TEMP/sha256sum" "$TEST_ARCHIVE"); sha=${sha%% *}; bytes=$(wc -c < "$TEST_ARCHIVE")
printf 'ga\tlinux\tx86_64\tjdk\thotspot\tv\tvendor\t99\t21+1\ttar.gz\thttps://artifacts.invalid/tar.gz\tjdk\t%s\t%s\t[]\n' "${bytes//[[:space:]]/}" "$sha" >> "$TEST_FIXTURE"
run 0 install vendor-21
mv "$TEMP/sha256sum" "$TOOLS/sha256sum"
check 'checksum mismatch/missing checksum/verifier, plus shasum and openssl adapters'

reset; index; row 21+1 vendor
TEST_ARTIFACT_STATUS=partial; run 1 install vendor-21; diagnostic 'artifact transfer failed'
TEST_ARTIFACT_STATUS=404; run 1 install vendor-21; diagnostic 'artifact transfer failed'
TEST_ARTIFACT_STATUS=200
awk 'BEGIN {FS=OFS="\t"} NR>1 {$13++} {print}' "$TEST_FIXTURE" > "$TEMP/modified"; mv "$TEMP/modified" "$TEST_FIXTURE"
rm -rf -- "$XDG_CACHE_HOME/jvm"
run 1 install vendor-21; diagnostic 'size mismatch'
TEST_ARCHIVE=$ROOT/tests/fixtures/archives/incomplete-jdk.tar.gz
index; row 21+1 vendor; run 1 install vendor-21; diagnostic 'exactly one JDK'
TEST_ARCHIVE=$ROOT/tests/fixtures/archives/wrong-arch.tar.gz
index; row 21+1 vendor; run 1 install vendor-21; diagnostic 'architecture does not match'
printf 'not an archive' > "$TEMP/broken"; TEST_ARCHIVE=$TEMP/broken
index; row 21+1 vendor; run 1 install vendor-21; diagnostic 'cannot inspect'
check 'incomplete transfer, HTTP failure, size mismatch, incomplete layout and invalid archive'

TEST_ARCHIVE=$ROOT/tests/fixtures/archives/jdk.tar.gz
reset; index; row 21+1 vendor
mv "$TOOLS/tar" "$TEMP/tar"
run 1 install vendor-21; diagnostic 'required utility missing: tar'
printf '#!%s\ncase "$1" in -x*) exit 1 ;; esac\nexec "%s" "$@"\n' "$BASH_BIN" "$(PATH=$ORIGINAL_PATH command -v tar)" > "$TOOLS/tar"
PATH=$ORIGINAL_PATH chmod +x "$TOOLS/tar"
run 1 install vendor-21; diagnostic 'extraction failed'
mv "$TEMP/tar" "$TOOLS/tar"
TEST_ARCHIVE=$ROOT/tests/fixtures/archives/jdk.zip
index; row 21+1 vendor zip
mv "$TOOLS/unzip" "$TEMP/unzip"
run 1 install vendor-21; diagnostic 'required utility missing: unzip'
mv "$TEMP/unzip" "$TOOLS/unzip"
TEST_ARCHIVE=$ROOT/tests/fixtures/archives/jdk.tar.gz
index; row 21+1 vendor
awk 'BEGIN {FS=OFS="\t"} NR>1 {$13=""} {print}' "$TEST_FIXTURE" > "$TEMP/modified"; mv "$TEMP/modified" "$TEST_FIXTURE"
run 0 install vendor-21
check 'missing extractors, extraction failure and optional advertised size'

for format in tar.gz zip; do
    for bad in traversal absolute outside-link link-parent duplicate cycle hard-outside; do
        archive=$ROOT/tests/fixtures/archives/$bad.$format
        [ -f "$archive" ] || continue
        TEST_ARCHIVE=$archive; reset; index; row 21+1 vendor "$format"
        run 1 install vendor-21; diagnostic 'unsafe'
        [ ! -e "$XDG_DATA_HOME/jvm/jdks/21+1-vendor" ] || fail "published $bad"
    done
done
TEST_ARCHIVE=$ROOT/tests/fixtures/archives/hardlink.tar.gz
reset; index; row 21+1 vendor; run 0 install vendor-21
check 'tar/ZIP traversal, absolute paths, link escapes/ancestors/cycles, duplicates and safe internal hardlinks'

TEST_ARCHIVE=$ROOT/tests/fixtures/archives/jdk.tar.gz
reset; index; row 21+1 vendor
mv "$TOOLS/curl" "$TEMP/curl"
run 0 install vendor-21
mv "$TEMP/curl" "$TOOLS/curl"
check 'wget-only metadata and artifact transfer'
else
    index; row 21+1 vendor
    run 0 install vendor-21
fi

# Existing complete installations and unrelated files survive all failure paths.
printf 'keep\n' > "$XDG_DATA_HOME/jvm/default"
index; row 22+1 vendor
TEST_DELAY=3
"$BASH_BIN" "$ROOT/jvm" install vendor-22 > "$TEMP/first.out" 2> "$TEMP/first.err" & first=$!
for attempt in {1..100}; do [ ! -e "$TEST_LOG.started" ] || break; sleep 0.1; done
[ -e "$TEST_LOG.started" ] || fail 'installer did not reach transfer'
run 0 list; contains '21+1-vendor'
[[ $(< "$TEMP/out") != *22+1* ]] || fail 'partial installation listed'
kill -TERM "$first"
wait "$first"; status=$?
first=
[ "$status" -ne 0 ] || fail 'interrupted install succeeded'
[ ! -e "$XDG_DATA_HOME/jvm/jdks/22+1-vendor" ] || fail 'interrupted install published'
for stage in "$XDG_DATA_HOME/jvm/tmp"/jdk-*; do
    [ ! -d "$stage" ] || fail 'interruption retained staging directory'
done
run 0 list; contains '21+1-vendor'
[ "$(< "$XDG_DATA_HOME/jvm/default")" = keep ] || fail 'default changed'
TEST_DELAY=0
TEST_PUBLISH_GATE=$TEMP/publish-gate
mkdir "$TEST_PUBLISH_GATE"
before=$(count_downloads)
TEST_PUBLISH_ROLE=first "$BASH_BIN" "$ROOT/jvm" install vendor-22 > "$TEMP/first.out" 2> "$TEMP/first.err" & first=$!
TEST_PUBLISH_ROLE=second "$BASH_BIN" "$ROOT/jvm" install vendor-22 > "$TEMP/second.out" 2> "$TEMP/second.err" & second=$!
for attempt in {1..300}; do
    if [ -e "$TEST_PUBLISH_GATE/first.ready" ] && [ -e "$TEST_PUBLISH_GATE/second.ready" ]; then break; fi
    sleep 0.1
done
[ -e "$TEST_PUBLISH_GATE/first.ready" ] && [ -e "$TEST_PUBLISH_GATE/second.ready" ] || {
    cat "$TEMP/first.err" "$TEMP/second.err" >&2
    fail 'concurrent installers did not both reach publication'
}
first_source=$(< "$TEST_PUBLISH_GATE/first.ready")
second_source=$(< "$TEST_PUBLISH_GATE/second.ready")
[ "$first_source" != "$second_source" ] || fail 'staging names collided'
for source in "$first_source" "$second_source"; do
    case "$source" in "$XDG_DATA_HOME/jvm/tmp/jdk-22+1-vendor."*) ;; *) fail 'staging name lacks jdk-ID prefix' ;; esac
done
run 0 list
[[ $(< "$TEMP/out") != *22+1* ]] || fail 'staged JDK appeared before publication'
: > "$TEST_PUBLISH_GATE/first.release"
wait "$first" || fail 'first concurrent installer failed'
first=
printf 'winner\n' > "$XDG_DATA_HOME/jvm/jdks/22+1-vendor/winner-marker"
: > "$TEST_PUBLISH_GATE/second.release"
wait "$second" || { cat "$TEMP/second.err" >&2; fail 'losing concurrent installer failed'; }
second=
[ "$(< "$TEST_PUBLISH_GATE/nested-copies")" = second ] || fail 'publication race did not exercise nested-copy cleanup'
[ "$(< "$TEST_PUBLISH_GATE/reclaimed-copies")" = second ] || fail 'nested copy was not moved back to private staging'
TEST_PUBLISH_GATE=
for output in "$TEMP/first.out" "$TEMP/second.out"; do
    [ "$(< "$output")" = 'Successfully installed 22+1-vendor' ] || fail 'concurrent installer did not report success'
done
after=$(count_downloads)
[ "$after" -eq "$((before+2))" ] || fail 'concurrent installers did not stage independently'
[ -f "$XDG_DATA_HOME/jvm/jdks/22+1-vendor/winner-marker" ] || fail 'loser damaged the winner'
[ ! -e "$XDG_DATA_HOME/jvm/jdks/tmp" ] || fail 'staging directory was created inside jdks'
[ ! -e "$XDG_DATA_HOME/jvm/jdks/22+1-vendor/22+1-vendor" ] || fail 'loser nested its home in the winner'
for stage in "$XDG_DATA_HOME/jvm/tmp"/jdk-*; do
    [ ! -d "$stage" ] || fail 'concurrent installer retained staging directory'
done
for entry in "$XDG_DATA_HOME/jvm/jdks/22+1-vendor"/jdk-* "$XDG_DATA_HOME/jvm/jdks/22+1-vendor"/.jvm-publish-*; do
    [ ! -e "$entry" ] || fail 'publication left a duplicate or marker in the winner'
done
index; row 23+1 vendor
TEST_PUBLISH_FAIL=1
run 1 install vendor-23; diagnostic 'cannot publish installation'
TEST_PUBLISH_FAIL=0
[ ! -e "$XDG_DATA_HOME/jvm/jdks/23+1-vendor" ] || fail 'failed publication exposed an installation'
mkdir -p "$XDG_DATA_HOME/jvm/jdks/23+1-vendor/bin"
run 1 install vendor-23; diagnostic 'incomplete or incompatible'
run 0 list
[[ $(< "$TEMP/out") != *23+1* ]] || fail 'unmanaged partial installation listed'
check 'independent staging, race loser success, publication failure and preservation of prior installation/default'

saved_data=$XDG_DATA_HOME; XDG_DATA_HOME=relative
index; row 24+1 vendor; run 0 install vendor-24
[ -f "$HOME/.local/share/jvm/jdks/24+1-vendor/.jvm-manifest" ] || fail 'relative XDG fallback failed'
XDG_DATA_HOME=$saved_data
[ ! -e "$XDG_CONFIG_HOME" ] && [ ! -e "$XDG_STATE_HOME" ] || fail 'unrelated storage touched'
printf 'PASS: %s installation checks (offline; host layouts simulated)\n' "$passed"
