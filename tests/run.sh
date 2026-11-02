#!/usr/bin/env bash
# Offline integration suite. No ordinary HOME/XDG locations or network used.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BASH_BIN=${BASH:-bash}
ORIGINAL_PATH=$PATH
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/jvm-tests.XXXXXXXX") || exit 1
trap 'rm -rf -- "$TEMP"' EXIT
trap 'exit 1' HUP INT TERM
export HOME="$TEMP/home with spaces"
export XDG_CACHE_HOME="$TEMP/cache with spaces"
export XDG_DATA_HOME="$TEMP/unused data" XDG_CONFIG_HOME="$TEMP/unused config" XDG_STATE_HOME="$TEMP/unused state"
mkdir -p "$HOME" "$TEMP/bin"
TOOLS="$TEMP/bin"
for tool in mkdir mktemp rm sed awk cat mv date cp; do
    path=$(command -v "$tool") || exit 1
    printf '#!%s\nexec "%s" "$@"\n' "$BASH_BIN" "$path" > "$TOOLS/$tool"
    chmod +x "$TOOLS/$tool" || exit 1
done
export PATH=$TOOLS
export TEST_SYSTEM=Linux TEST_MACHINE=x86_64 TEST_LIBC=glibc
export TEST_FIXTURE="$ROOT/tests/fixtures/latest.tsv"
export TEST_PLAN=200 TEST_LOG="$TEMP/requests" TEST_COUNTER="$TEMP/counter"
export TEST_HEADERS=etag

# Fakes are launched by the test Bash, with no runtime interpreter dependencies.
for tool in uname ldd getconf curl wget cygpath; do
    printf '#!%s\n' "$BASH_BIN" > "$TOOLS/$tool"
    case "$tool" in
    uname) printf '%s\n' 'case "$1" in -s) echo "$TEST_SYSTEM" ;; -m) echo "$TEST_MACHINE" ;; esac' >> "$TOOLS/$tool" ;;
    ldd) printf '%s\n' 'case "$TEST_LIBC" in glibc) echo "ldd (GNU libc) 2.39" ;; musl) echo "musl libc" >&2; exit 1 ;; *) exit 1 ;; esac' >> "$TOOLS/$tool" ;;
    getconf) printf '%s\n' 'exit 1' >> "$TOOLS/$tool" ;;
    cygpath) printf '%s\n' 'printf "%s/%s\n" "$TEST_DRIVE_ROOT" "${2:3}"' >> "$TOOLS/$tool" ;;
    curl|wget) cat >> "$TOOLS/$tool" <<'EOF'
adapter=${0##*/}
if [ "${1:-}" = --help ]; then
    echo "${TEST_WGET_CAPS:---https-only --header --server-response --timeout --tries}"
    exit 0
fi
printf '%s\n' "$adapter $*" >> "$TEST_LOG"
count=0
[ ! -f "$TEST_COUNTER" ] || read -r count < "$TEST_COUNTER"
count=$((count+1)); echo "$count" > "$TEST_COUNTER"
case "$TEST_PLAN" in
    retry) if [ "$count" -eq 1 ]; then status=304; else status=200; fi ;;
    *) status=$TEST_PLAN ;;
esac
output= headers=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --output|-O) output=$2; shift ;;
        --dump-header) headers=$2; shift ;;
    esac
    shift
done
if [ "$status" = fail ]; then echo 'simulated failure' >&2; exit 7; fi
if [ "$adapter" = wget ]; then
    printf '  HTTP/1.1 %s Status\r\n' "$status" >&2
    if [ "$TEST_HEADERS" = etag ]; then printf '  ETag: W/"opaque-value"\r\n' >&2
    else printf '  Last-Modified: Mon, 19 Oct 2026 12:00:00 GMT\r\n' >&2; fi
else
    printf 'HTTP/1.1 %s Status\r\n' "$status" > "$headers"
    if [ "$TEST_HEADERS" = etag ]; then printf 'ETag: W/"opaque-value"\r\n' >> "$headers"
    else printf 'Last-Modified: Mon, 19 Oct 2026 12:00:00 GMT\r\n' >> "$headers"; fi
fi
if [ "$status" = 200 ]; then cat "$TEST_FIXTURE" > "$output"; fi
if [ "$adapter" = curl ]; then printf '%s' "$status"
elif [ "$status" != 200 ]; then exit 8; fi
EOF
    ;;
    esac
    PATH=$ORIGINAL_PATH chmod +x "$TOOLS/$tool"
done

passed=0
fail() { printf 'FAIL: %s\n' "$*" >&2; cat "$TEMP/err" >&2; exit 1; }
check() { passed=$((passed+1)); printf 'ok %s - %s\n' "$passed" "$*"; }
run() {
    local expected=$1 actual
    shift
    (cd "$TEMP" && "$BASH_BIN" "$ROOT/jvm" "$@") > "$TEMP/out" 2> "$TEMP/err"
    actual=$?
    [ "$actual" -eq "$expected" ] || fail "exit $actual, expected $expected: $*"
    if [ "$expected" -ne 0 ]; then
        [ ! -s "$TEMP/out" ] || fail 'failure printed partial command results'
    fi
}
contains() { [[ $(< "$TEMP/out") = *"$1"* ]] || fail "missing output: $1"; }
diagnostic() { [[ $(< "$TEMP/err") = *"$1"* ]] || fail "missing diagnostic: $1"; }
quiet() { [ ! -s "$TEMP/err" ] || fail 'expected silent success/fallback'; }
aligned() {
    awk '
        {
            offset=0; field=1; start=1; overflow=0; chars=0; tabs=0
            for (i=1; i<=length($0); i++) {
                char=substr($0,i,1)
                if (char=="\t") {
                    if (!start && chars>=32) overflow+=(int(chars/8)+1)*8-32
                    offset=(int(offset/8)+1)*8; start=1; tabs++
                    if (tabs>4) exit 1
                }
                else {
                    if (start) {
                        if (NR==1) column[field]=offset
                        else if (column[field]+overflow!=offset) exit 1
                        field++; start=0; chars=0; tabs=0
                    }
                    offset++; chars++
                }
            }
            if (field!=5 || $0 ~ /\t$/) exit 1
        }
    ' "$TEMP/out" || fail 'columns do not align at 8-column tab stops'
}
reset_cache() { rm -rf -- "$XDG_CACHE_HOME/jvm" "$HOME/.cache"; rm -f "$TEST_COUNTER" "$TEST_LOG"; }
stale() {
    local entry
    for entry in "$XDG_CACHE_HOME"/jvm/all-*; do
        { IFS= read -r url; IFS= read -r time; printf '%s\n0\n' "$url"; cat; } < "$entry" > "$TEMP/stale"
        mv "$TEMP/stale" "$entry"
    done
}
fixture() { TEST_FIXTURE=$ROOT/tests/fixtures/latest.tsv; export TEST_FIXTURE; }

# Help and version run even with no external tools.
saved_path=$PATH; PATH=/nonexistent
run 0 --help
contains 'available, a [-t] [selector]'; contains 'distro-major (temurin-21)'
contains 'list, l [selector]'
contains '21+, 21..25, temurin-21+'; contains 'remote range ties use C ID order'
contains 'finds and installs Java Development Kits'; contains 'even offline'
lines=0; while IFS= read -r line; do lines=$((lines+1)); done < "$TEMP/out"
[ "$lines" -le 50 ] || fail 'help is too verbose'
contains 'Shell setup (once, in your shell profile):'
contains 'Windows Bash:'; contains 'cygpath -u'
main_help=$(< "$TEMP/out")
run 0 --help
[ "$(< "$TEMP/out")" = "$main_help" ] || fail 'main help differs'
run 0 available --help
[ "$(< "$TEMP/out")" = "$main_help" ] || fail 'available --help differs'
run 0 uninstall --help
[ "$(< "$TEMP/out")" = "$main_help" ] || fail 'uninstall --help differs'
run 0 list --help
[ "$(< "$TEMP/out")" = "$main_help" ] || fail 'list --help differs'
run 0 default --help
[ "$(< "$TEMP/out")" = "$main_help" ] || fail 'default --help differs'
for cmd in available list install uninstall default home env exec a l i u d h e x; do
    run 0 "$cmd" --help; quiet
    [ "$(< "$TEMP/out")" = "$main_help" ] || fail "help differs: $cmd"
done
for cmd in help shell s av lis ins un def en ho; do run 2 "$cmd"; done
for cmd in default home env d h e; do
    run 2 "$cmd" -i
    [ "$(< "$TEMP/err")" = 'jvm: Missing selector' ] || fail 'missing selector diagnostic'
done
run 0 --version
run 2 install
[ "$(< "$TEMP/err")" = 'jvm: usage: jvm install <selector>'$'\n''for more information run: jvm install --help' ] || fail 'incorrect no-argument install guidance'
run 0 install --help
[ ! -s "$TEMP/err" ] || fail 'install --help wrote a diagnostic'
[ "$(< "$TEMP/out")" = "$main_help" ] || fail 'install --help differs from main help'
run 2 uninstall
[ "$(< "$TEMP/err")" = 'jvm: usage: jvm uninstall <selector>'$'\n''for more information run: jvm uninstall --help' ] || fail 'incorrect no-argument uninstall guidance'
run 2 install -help
diagnostic 'unsupported flag:'
PATH=$saved_path
run 2; run 2 install; run 2 available 21 extra; run 2 available ''
check 'help/version independent of network and archive utilities; usage exit codes'
if [ "${1:-}" = --help-only ]; then exit 0; fi

run 0 available; quiet
awk -F '\t+' 'NR==1 && (NF!=4 || $1!="ID" || $2!="DISTRIBUTION" || $3!="VERSION" || $4!="JVM") {exit 1}' "$TEMP/out" || fail 'unexpected listing columns'
contains '21.0.12+9-temurin'; contains '8.0.482+8-temurin'
contains '21.0.12+9-semeru'
awk -F '\t+' 'NR>1 && $1 !~ ("-" $2 "$") {exit 1}' "$TEMP/out" || fail 'JVM suffix added to ID'
[[ $(< "$TEMP/out") != *'jre-only'* ]] || fail 'JRE leaked'
contains '99.0.2-temurin'
awk -F '\t+' 'NR>1 && $1=="99.0.2-temurin" {n++} END {if(n!=1) exit 1}' "$TEMP/out" || fail 'EA filtering/archive deduplication'
lines=0; while IFS= read -r line; do lines=$((lines+1)); done < "$TEMP/out"
[ "$lines" -eq 7 ] || fail 'archive variants not deduplicated'
check 'GA/EA/JDK/platform/archive filters, full IDs and archive deduplication'
aligned
check 'listing headers and mixed-length values align with 8-column tabs'
run 0 available 21; contains '21.0.12+9-temurin'; contains '21.0.12+9-semeru'
run 0 available temurin; contains '8.0.482+8-temurin'; contains '25.0.1+7-temurin'
[[ $(< "$TEMP/out") != *foo-bar* ]] || fail 'distro-only filter leaked'
run 0 available foo-bar; contains '17.0.20.1+1-foo-bar'
run 0 available temurin-8; contains '8.0.482+8-temurin'
run 0 available foo-bar-17; contains '17.0.20.1+1-foo-bar'
run 2 available 21.0.12+9-temurin; diagnostic 'selector must be'
run 2 available '../temurin-21'; run 2 available 0
run 0 available semeru; quiet; contains '21.0.12+9-semeru'; contains 'openj9'
run 1 available 999; diagnostic 'No JDK found matching:'
check 'major, distro, legacy, hyphenated distro, removed exact IDs and missing match'
[ "$(< "$TEST_COUNTER")" -eq 1 ] || fail 'selectors did not share the latest cache'
[[ $(< "$TEST_LOG") = *'/metadata/all/linux/x86_64/jdk-latest.tsv'* ]] || fail 'wrong discovery endpoint'
check 'all selectors use one latest index and cache; no history requests'
before=$(< "$TEST_COUNTER"); TEST_PLAN=fail; run 0 available; quiet
[ "$(< "$TEST_COUNTER")" = "$before" ] || fail 'fresh cache fetched'
check 'fresh cache performs no request'
mv "$TOOLS/curl" "$TEMP/saved-curl"; mv "$TOOLS/wget" "$TEMP/saved-wget"
run 0 available; quiet
stale; run 0 available; quiet
reset_cache; run 1 available; diagnostic 'install curl or wget'
mv "$TEMP/saved-curl" "$TOOLS/curl"; mv "$TEMP/saved-wget" "$TOOLS/wget"
check 'fresh/stale valid cache works without downloaders; missing initial downloader is actionable'

for adapter in curl wget; do
    if [ "$adapter" = wget ]; then mv "$TOOLS/curl" "$TEMP/curl"; fi
    reset_cache; fixture; TEST_PLAN=200; TEST_HEADERS=etag
    run 0 available; quiet
    stale; TEST_PLAN=304; run 0 available; quiet
    [[ $(< "$TEST_LOG") = *'If-None-Match: W/"opaque-value"'* ]] || fail 'ETag not preserved'
    check "$adapter: initial 200 and conditional 304 reuse"
    stale; snapshot=$(< "$XDG_CACHE_HOME/jvm/all-linux-x86_64-jdk-latest-v1")
    TEST_PLAN=fail; run 0 available; quiet
    [ "$(< "$XDG_CACHE_HOME/jvm/all-linux-x86_64-jdk-latest-v1")" = "$snapshot" ] || fail 'failed refresh changed cache/check time'
    stale; TEST_PLAN=500; run 0 available; quiet
    check "$adapter: transfer/HTTP failure silently retains valid stale cache"
    stale; TEST_PLAN=200; TEST_FIXTURE=$ROOT/tests/fixtures/bad-header.tsv
    run 0 available; quiet; contains '21.0.12+9-temurin'
    before=$(< "$TEST_COUNTER"); TEST_PLAN=fail; run 0 available; quiet
    [ "$(< "$TEST_COUNTER")" = "$before" ] || fail 'trusted replacement not cached'
    check "$adapter: successful response is trusted and cached without validation"
    TEST_PLAN=200
    fixture; stale
    sed 's/25[.]0[.]1+7/25.0.1+8/g' "$TEST_FIXTURE" > "$TEMP/replacement.tsv"
    TEST_FIXTURE=$TEMP/replacement.tsv
    run 0 available 25; quiet; contains '25.0.1+8-temurin'; fixture
    check "$adapter: valid 200 replaces cache"
    reset_cache; TEST_PLAN=retry; run 0 available; quiet
    [ "$(< "$TEST_COUNTER")" -eq 2 ] || fail '304 without body not retried'
    check "$adapter: 304 without usable body retries unconditionally"
    printf '%s\n0\n\n\n' 'https://jbangdev.github.io/jdkdb-index/metadata/all/linux/x86_64/jdk-latest.tsv' > "$XDG_CACHE_HOME/jvm/all-linux-x86_64-jdk-latest-v1"
    rm -f "$TEST_COUNTER"; TEST_PLAN=retry; run 0 available; quiet
    [ "$(< "$TEST_COUNTER")" -eq 2 ] || fail '304 with missing body not retried'
    check "$adapter: missing cached body triggers unconditional retry"
    reset_cache; TEST_PLAN=304; run 1 available; diagnostic 'cannot obtain metadata'
    reset_cache; TEST_PLAN=fail; run 1 available; diagnostic 'cannot obtain metadata'
    check "$adapter: repeated 304 and failed initial fetch fail clearly"
    reset_cache; TEST_PLAN=200; TEST_HEADERS=modified; run 0 available
    stale; TEST_PLAN=304; run 0 available; quiet
    [[ $(< "$TEST_LOG") = *'If-Modified-Since: Mon, 19 Oct 2026 12:00:00 GMT'* ]] || fail 'Last-Modified missing'
    check "$adapter: Last-Modified fallback"
    stale; TEST_PLAN=200; : > "$TEMP/no-body.tsv"; TEST_FIXTURE=$TEMP/no-body.tsv
    run 0 available; quiet; contains '21.0.12+9-temurin'
    reset_cache; run 1 available; diagnostic 'HTTP 200'
    fixture; run 0 available; quiet
    check "$adapter: empty HTTP body preserves cache or fails if no cache exists"
done
# wget without conditional-header support makes an unconditional request.
export TEST_WGET_CAPS='--https-only --server-response --timeout --tries'
stale; TEST_PLAN=200; run 0 available; quiet
last=; while IFS= read -r line; do last=$line; done < "$TEST_LOG"
[[ $last != *'If-Modified-Since'* ]] || fail 'unsupported conditional header used'
check 'wget capability fallback to unconditional GET'
reset_cache; TEST_WGET_CAPS='--header --timeout --tries'; run 1 available
diagnostic 'wget lacks --https-only'
check 'wget without safe HTTPS redirects fails clearly'
unset TEST_WGET_CAPS
mv "$TEMP/curl" "$TOOLS/curl"
TEST_PLAN=200; TEST_HEADERS=etag

for data in bad-header empty-field missing-column extra-column bad-escape bad-digest bad-feature unsafe-id; do
    reset_cache; TEST_FIXTURE=$ROOT/tests/fixtures/$data.tsv
    run 0 available; quiet
    check "trust upstream $data without validation"
done
for conflict in conflict conflict-archive; do
    reset_cache; TEST_FIXTURE=$ROOT/tests/fixtures/$conflict.tsv
    run 0 available; contains '21.0.12+9-temurin'; quiet
    lines=0; while IFS= read -r line; do lines=$((lines+1)); done < "$TEMP/out"
    [ "$lines" -eq 2 ] || fail 'conflicting ID was not deduplicated'
    run 0 available temurin; contains '21.0.12+9-temurin'; quiet
    check "list $conflict successfully, including distro selection from cache"
done
TEST_FIXTURE=$ROOT/tests/fixtures/conflict-unrelated.tsv; reset_cache
run 0 available 8; quiet; contains '8.0.482+8-temurin'
run 0 available; contains '8.0.482+8-temurin'; contains '21.0.12+9-temurin'; quiet
run 0 available 21; contains '21.0.12+9-temurin'; quiet
check 'mixed inventory and short selectors continue despite conflicts'
# More than two variants must not repeat warnings or result rows.
cat "$TEST_FIXTURE" > "$TEMP/repeated.tsv"
sed -n '2,3p' "$TEST_FIXTURE" >> "$TEMP/repeated.tsv"
TEST_FIXTURE=$TEMP/repeated.tsv; reset_cache; run 0 available
lines=0; while IFS= read -r line; do lines=$((lines+1)); done < "$TEMP/err"
[ "$lines" -eq 0 ] || fail 'duplicate variants emitted a diagnostic'
check 'duplicate variants are collapsed without diagnostics'
sed 's/temurin/other-distro/g' "$ROOT/tests/fixtures/conflict.tsv" > "$TEMP/other.tsv"
sed -n '2,3p' "$TEMP/other.tsv" >> "$TEMP/repeated.tsv"
reset_cache; run 0 available
quiet
contains '21.0.12+9-temurin'; contains '21.0.12+9-other-distro'
lines=0; while IFS= read -r line; do lines=$((lines+1)); done < "$TEMP/err"
[ "$lines" -eq 0 ] || fail 'duplicate IDs emitted diagnostics'
check 'different builds sharing IDs preserve all listing identities silently'
reset_cache; TEST_FIXTURE=$ROOT/tests/fixtures/equivalent-features.tsv
run 0 available -t; quiet
awk -F '\t+' 'NR==2 && $5!="beta,alpha" {exit 1} END {if(NR!=2) exit 1}' "$TEMP/out" || fail 'TYPE must preserve first-row feature order when deduplicating'
check 'displayed features and unused checksums have no effect on identity'
fixture
reset_cache; TEST_FIXTURE=$ROOT/tests/fixtures/crlf.tsv; run 0 available; quiet
check 'CRLF transport accepted'
reset_cache; TEST_FIXTURE=$ROOT/tests/fixtures/escaped.tsv; run 0 available; quiet
contains '21.0.12+9-temurin'
check 'unused escaped fields stay inert and do not affect listing'
[ ! -e "$TEMP/PWNED" ] || fail 'metadata was executed'
reset_cache; TEST_FIXTURE=$ROOT/tests/fixtures/empty.tsv; run 0 available; quiet
check 'header-only empty inventory succeeds'
aligned
awk 'BEGIN {FS=OFS="\t"} NR==1 {print} NR==2 {
    $9="21+123"
    $7="xxxxxxxx"; print
    $7="xxxxxxxxx"; print
    $7="xxxxxxxxxx"; print
    $7="very-long-distribution-name"; $9="21.0.123+456"; print
}' "$ROOT/tests/fixtures/latest.tsv" > "$TEMP/alignment.tsv"
TEST_FIXTURE=$TEMP/alignment.tsv; reset_cache; run 0 available; quiet; aligned
awk 'NR==1 {if ($0 !~ /^ID\t\t\t\tDISTRIBUTION/) exit 1}' "$TEMP/out" || fail 'long ID widened padding beyond four tab stops'
contains '21+123-xxxxxxxx'; contains '21+123-xxxxxxxxx'; contains '21+123-xxxxxxxxxx'
contains '21.0.123+456-very-long-distribution-name'
run 0 available xxxxxxxxx; quiet; aligned; contains '21+123-xxxxxxxxx'
check 'tab boundaries and long IDs keep padding within four tabs without truncation'
TEST_FIXTURE=$ROOT/tests/fixtures/version-source.tsv; reset_cache
run 0 available; quiet; aligned
contains '19-21.0.12+9-temurin'; contains '19-21.0.12+10-temurin'
contains '19+1'
[[ $(< "$TEMP/out") != *19+2* ]] || fail 'duplicate ID replaced first display row'
lines=0; while IFS= read -r line; do lines=$((lines+1)); done < "$TEMP/out"
[ "$lines" -eq 4 ] || fail 'deduplication did not use version-based IDs'
run 0 available temurin-19; quiet; contains '19-21.0.12+10-temurin'
awk -F '\t+' 'NR>1 && $3!="19+1" {exit 1}' "$TEMP/out" || fail 'VERSION does not show java_version'
run 1 available 21; diagnostic 'No JDK found matching:'
run 0 available legacy-vendor-8; quiet; contains '8-1.8.0_482-b08-legacy-vendor'
check 'java_version controls display and major selection; IDs preserve version with a Java-major prefix'
TEST_FIXTURE=$ROOT/tests/fixtures/jvm-impls.tsv; reset_cache
run 0 available; quiet; aligned
contains '21.0.12+9-multi-vendor'
lines=0; while IFS= read -r line; do lines=$((lines+1)); done < "$TEMP/out"
[ "$lines" -eq 2 ] || fail 'colliding version-distro IDs were not collapsed'
awk -F '\t+' 'NR>1 && $1 !~ ("-" $2 "$") {exit 1}' "$TEMP/out" || fail 'JVM suffix added to ID'
before=$(< "$TEST_COUNTER")
for selector in 21 multi-vendor multi-vendor-21; do
    run 0 available "$selector"; quiet
    contains '21.0.12+9-multi-vendor'
done
[ "$(< "$TEST_COUNTER")" = "$before" ] || fail 'JVM-inclusive selectors fetched additional indexes'
awk 'NR==1 {print} NR>1 {rows[NR]=$0} END {for (i=NR; i>1; i--) print rows[i]}' "$TEST_FIXTURE" > "$TEMP/reversed-jvms.tsv"
TEST_FIXTURE=$TEMP/reversed-jvms.tsv; reset_cache; run 0 available; quiet
contains '21.0.12+9-multi-vendor'; contains 'graalvm'
awk -F '\t+' 'NR>1 && $1!="21.0.12+9-multi-vendor" {exit 1}' "$TEMP/out" || fail 'non-HotSpot ID gained a suffix'
check 'short IDs collapse across JVMs silently, retain first-row display fields and share one cache'
fixture

# Simulated detection; fixtures are adapted only in the fake response data.
for platform in 'Linux aarch64 glibc linux aarch64' 'Linux x86_64 musl linux-musl x86_64' 'Darwin arm64 glibc macosx aarch64' 'CYGWIN_NT-10.0 AMD64 glibc windows x86_64' 'MSYS_NT-10.0 x86_64 glibc windows x86_64' 'MINGW64_NT-10.0 ARM64 glibc windows aarch64'; do
    read -r TEST_SYSTEM TEST_MACHINE TEST_LIBC os arch <<< "$platform"
    sed "s/linux/$os/g; s/x86_64/$arch/g" "$ROOT/tests/fixtures/latest.tsv" > "$TEMP/platform.tsv"
    TEST_FIXTURE=$TEMP/platform.tsv; reset_cache; run 0 available; quiet; aligned
    contains '21.0.12+9-temurin'
    [[ $(< "$TEST_LOG") = *"/metadata/all/$os/$arch/jdk-latest.tsv"* ]] || fail 'wrong platform endpoint'
    check "simulated $TEST_SYSTEM/$TEST_MACHINE/$TEST_LIBC"
done
TEST_SYSTEM=Linux; TEST_MACHINE=x86_64; TEST_LIBC=unknown; reset_cache; run 1 available; diagnostic 'libc'
TEST_LIBC=glibc; TEST_MACHINE=mystery; run 1 available; diagnostic 'architecture'
TEST_MACHINE=x86_64; TEST_SYSTEM=Other; run 1 available; diagnostic 'operating system'
TEST_SYSTEM=Linux; TEST_MACHINE=armv7l; run 1 available; diagnostic 'ARM ABI'
TEST_SYSTEM=Linux; fixture
TEST_MACHINE=x86_64
check 'unknown host/architecture/libc fail explicitly'

reset_cache; saved_cache=$XDG_CACHE_HOME; XDG_CACHE_HOME=relative
run 0 available; quiet
[ -f "$HOME/.cache/jvm/all-linux-x86_64-jdk-latest-v1" ] || fail 'relative XDG not ignored'
XDG_CACHE_HOME=$saved_cache
saved_home=$HOME; HOME=relative; XDG_CACHE_HOME=relative; run 1 available; diagnostic 'absolute HOME'
XDG_CACHE_HOME=$saved_cache; run 0 available; quiet; HOME=$saved_home
check 'paths with spaces, relative XDG fallback, missing HOME and absolute override'

TEST_SYSTEM=MINGW64_NT-10.0; export TEST_DRIVE_ROOT=$TEMP/converted-drive
sed 's/linux/windows/g' "$ROOT/tests/fixtures/latest.tsv" > "$TEMP/windows.tsv"
TEST_FIXTURE=$TEMP/windows.tsv; XDG_CACHE_HOME='C:/cache with spaces'
run 0 available; quiet
[ -f "$TEST_DRIVE_ROOT/cache with spaces/jvm/all-windows-x86_64-jdk-latest-v1" ] || fail 'drive path conversion failed'
XDG_CACHE_HOME=$saved_cache
check 'simulated Windows absolute drive path conversion stays in test workspace'

[ ! -e "$XDG_DATA_HOME" ] && [ ! -e "$XDG_CONFIG_HOME" ] && [ ! -e "$XDG_STATE_HOME" ] || fail 'unrelated storage touched'
printf 'PASS: %s checks (offline; platform cases simulated)\n' "$passed"
[ "${1:-}" != --discovery ] || exit 0
PATH=$ORIGINAL_PATH "$BASH_BIN" "$ROOT/tests/install.sh" || exit $?
PATH=$ORIGINAL_PATH "$BASH_BIN" "$ROOT/tests/home-env.sh"
