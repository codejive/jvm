#!/usr/bin/env bash
# Offline integration checks using real archive tools and inert tiny JDK files.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BASH_BIN=${BASH:-bash}
ORIGINAL_PATH=$PATH
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/jvm-install-tests.XXXXXXXX") || exit 1
# Fixtures and exact home/exec expectations share the manager's physical paths.
# TMPDIR can name an alias such as /var on macOS or a Windows runner mount.
TEMP=$(cd "$TEMP" && pwd -P) || exit 1
cleanup() {
    if [ -n "${TEST_PUBLISH_GATE:-}" ]; then
        : > "$TEST_PUBLISH_GATE/first.release"
        : > "$TEST_PUBLISH_GATE/second.release"
    fi
    if [ -n "${TEST_DEFAULT_GATE:-}" ]; then
        : > "$TEST_DEFAULT_GATE/first.release"
        : > "$TEST_DEFAULT_GATE/second.release"
    fi
    for pid in "${first:-}" "${second:-}"; do
        [ -z "$pid" ] || { kill -TERM "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; }
    done
    rm -rf -- "$TEMP"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
mkdir -p "$TEMP/project with spaces"
cd "$TEMP/project with spaces" || exit 1
export HOME="$TEMP/home with spaces" XDG_DATA_HOME="$TEMP/data with spaces"
export XDG_CACHE_HOME="$TEMP/cache with spaces" XDG_CONFIG_HOME="$TEMP/config" XDG_STATE_HOME="$TEMP/state"
mkdir -p "$HOME" "$TEMP/bin"
TOOLS=$TEMP/bin
export MSYS=winsymlinks:nativestrict
for tool in ln readlink mkdir mktemp rm rmdir sed awk cat cmp mv date cp sleep wc find tar gzip unzip sha256sum openssl; do
    path=$(command -v "$tool") || continue
    printf '#!%s\nexec "%s" "$@"\n' "$BASH_BIN" "$path" > "$TOOLS/$tool"
    chmod +x "$TOOLS/$tool" || exit 1
done
printf '#!%s\nprintf "%%s\\n" "$2"\n' "$BASH_BIN" > "$TOOLS/cygpath"
printf '#!%s\ncat > /dev/null\nln -s "$JVM_TARGET" "$JVM_LINK"\n' "$BASH_BIN" > "$TOOLS/cmd.exe"
chmod +x "$TOOLS/cygpath" "$TOOLS/cmd.exe"
export TEST_SYSTEM=Linux TEST_MACHINE=x86_64 TEST_OS=linux
export TEST_LOG="$TEMP/requests" TEST_FIXTURE="$TEMP/index.tsv"
export TEST_ARCHIVE="$ROOT/tests/fixtures/archives/jdk.tar.gz"
export TEST_ARTIFACT_STATUS=200 TEST_DELAY=0 TEST_EXTRA_LOCAL=
export TEST_PUBLISH_GATE= TEST_PUBLISH_FAIL=0 TEST_REAL_MV TEST_REAL_RM
export TEST_REMOVE_FAIL=0 TEST_REMOVE_DELETE_FAIL=0 TEST_REMOVE_LOG="$TEMP/removals"
export TEST_DEFAULT_FAIL=0 TEST_DEFAULT_FAIL_MAJOR=0 TEST_DEFAULT_INTERRUPT=0
export TEST_DEFAULT_GATE= TEST_DEFAULT_LINK=default TEST_REAL_LN
TEST_REAL_LN=$(command -v ln)
TEST_REAL_MV=$(command -v mv)
TEST_REAL_RM=$(command -v rm)
for tool in uname ldd curl wget mv rm; do
    printf '#!%s\n' "$BASH_BIN" > "$TOOLS/$tool"
    case "$tool" in
        uname) printf '%s\n' 'echo "$TEST_SYSTEM $TEST_MACHINE"' >> "$TOOLS/$tool" ;;
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
case "${2:-}" in
    */jvm/tmp/default.*/link)
        [ "$TEST_DEFAULT_FAIL_MAJOR" != 1 ] || [ "${3:-}" != "$XDG_DATA_HOME/jvm/jdks/21" ] || exit 1
        if [ "$TEST_DEFAULT_INTERRUPT" = 2 ] || [ "$TEST_DEFAULT_FAIL" = 2 ]; then
            rm "$XDG_DATA_HOME/jvm/jdks/default" || exit 99
            [ "$TEST_DEFAULT_INTERRUPT" != 2 ] || kill -TERM "$PPID"
            exit 1
        fi
        [ "$TEST_DEFAULT_INTERRUPT" != 1 ] || { kill -TERM "$PPID"; exit 1; }
        [ "$TEST_DEFAULT_FAIL" != 1 ] || exit 1 ;;
esac
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
        if [ -n "${TEST_EXTRA_LOCAL:-}" ]; then
            # Publish the competing installation as a directory rename. Copying
            # its relative links can fail on MSYS2 before their targets exist.
            mv "$TEST_EXTRA_LOCAL" "$XDG_DATA_HOME/jvm/jdks/" || exit 99
        fi
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
printf '#!%s\n' "$BASH_BIN" > "$TOOLS/ln"
cat >> "$TOOLS/ln" <<'EOF'
if [ -n "$TEST_DEFAULT_GATE" ] && [ "${3:-}" = "$XDG_DATA_HOME/jvm/jdks/$TEST_DEFAULT_LINK" ]; then
    : > "$TEST_DEFAULT_GATE/$TEST_DEFAULT_ROLE.ready"
    while [ ! -e "$TEST_DEFAULT_GATE/$TEST_DEFAULT_ROLE.release" ]; do sleep 0.05; done
fi
exec "$TEST_REAL_LN" "$@"
EOF
export PATH=$TOOLS
passed=0
fail() { printf 'FAIL: %s\n' "$*" >&2; cat "$TEMP/err" >&2; exit 1; }
dangling_link() {
    # Older MSYS2 cannot create a native symlink to a nonexistent target.
    # Create a directory link first, then remove its temporary target.
    mkdir "$1" && ln -s "$1" "$2" && rmdir "$1" || fail 'cannot prepare dangling link'
}
check() { passed=$((passed+1)); printf 'ok %s - %s\n' "$passed" "$*"; }
run() {
    local expected=$1 actual
    shift
    "$BASH_BIN" "$ROOT/jvm" "$@" > "$TEMP/out" 2> "$TEMP/err"; actual=$?
    [ "$expected" -eq "$actual" ] || fail "exit $actual, expected $expected: $*"
    if [ "$expected" -ne 0 ]; then [ ! -s "$TEMP/out" ] || fail 'partial command output on failure'; fi
    case "$1" in
        install|uninstall) [ ! -s "$TEMP/out" ] || fail 'informational messages leaked to stdout' ;;
        default) if [ "$#" -gt 1 ] && { [ "${2:-}" != -v ] || [ "$#" -gt 3 ]; }; then
            [ ! -s "$TEMP/out" ] || fail 'default selection leaked to stdout'; fi ;;
    esac
}
contains() { [[ $(< "$TEMP/out") = *"$1"* ]] || fail "missing output: $1"; }
diagnostic() { [[ $(< "$TEMP/err") = *"$1"* ]] || fail "missing diagnostic: $1"; }
reset() { rm -rf -- "$XDG_DATA_HOME/jvm" "$XDG_CACHE_HOME/jvm"; rm -f "$TEST_LOG" "$TEST_LOG.started"; }
index() { printf 'trusted header\n' > "$TEST_FIXTURE"; rm -rf -- "$XDG_CACHE_HOME/jvm"; }
row() {
    local version=$1 distro=$2 format=${3:-tar.gz} archive=${4:-$TEST_ARCHIVE} java_version=${5:-$1} sha bytes
    java_version=${java_version#1.}; java_version=${java_version%%[^0-9]*}+99
    sha=$(sha256sum "$archive"); sha=${sha%% *}
    bytes=$(wc -c < "$archive"); bytes=${bytes//[[:space:]]/}
    printf 'ga\t%s\tx86_64\tjdk\topenj9\tvendor\t%s\t%s\t%s\t%s\thttps://artifacts.invalid/%s\tjdk.%s\t%s\t%s\t[]\n' "$TEST_OS" "$distro" "$java_version" "$version" "$format" "$format" "$format" "$bytes" "$sha" >> "$TEST_FIXTURE"
}
count_downloads() { awk '/https:\/\/artifacts.invalid/ {n++} END {print n+0}' "$TEST_LOG"; }

manifest_checks() {
    local manifest before mode
    reset; index; row 21+1 vendor; row 21+1 vendor zip "$ROOT/tests/fixtures/archives/jdk.zip"
    # Future upstream columns, empty cells, inert escapes and CRLF must survive.
    awk 'BEGIN {FS=OFS="\t"} NR==1 {print; next} {
        $6="vendor\\t$(exit 99)"; $12=""; $13=""; $14=toupper($14)
        $16=""; $17="future\\nvalue"; $18=""; $19=""
        printf "%s\r\n",$0
    }' "$TEST_FIXTURE" > "$TEMP/extended-index"
    mv "$TEMP/extended-index" "$TEST_FIXTURE"
    sed -n '2p' "$TEST_FIXTURE" > "$TEMP/expected-source"
    run 0 install vendor-21
    manifest=$XDG_DATA_HOME/jvm/jdks/21+1-vendor/.jvm-manifest
    sed -n '2p' "$manifest" > "$TEMP/actual-source"
    cmp "$TEMP/expected-source" "$TEMP/actual-source" || fail 'manifest changed the selected original TSV row'
    awk 'NR==1 && $0!="jvm-manifest-v1" {exit 1} NR==3 && $0!="" {exit 1}
        END {if (NR!=3) exit 1}' "$manifest" || fail 'incorrect manifest envelope'
    # Readers must also accept future local columns without networking.
    awk 'NR==3 {$0="future local value\t"} {print}' "$manifest" > "$TEMP/extended-manifest"
    mv "$TEMP/extended-manifest" "$manifest"
    cp "$manifest" "$TEMP/valid-manifest"
    before=$(< "$TEST_LOG")
    rm -rf -- "$XDG_CACHE_HOME/jvm"
    run 0 list 21; contains '21+1-vendor'; contains '21+99'
    run 0 home 21+1-vendor; contains '/21+1-vendor'
    run 0 install 21+1-vendor; diagnostic 'Already installed'
    [ "$(< "$TEST_LOG")" = "$before" ] || fail 'manifest lookup accessed network'
    for mode in marker truncated extra short-source; do
        awk -v mode="$mode" 'BEGIN {FS=OFS="\t"}
            mode=="marker" && NR==1 {$0="jvm-manifest-v999"}
            mode=="truncated" && NR==3 {next}
            mode=="short-source" && NR==2 {$0="ga\tlinux"}
            {print} END {if (mode=="extra") print "unexpected fourth line"}
        ' "$TEMP/valid-manifest" > "$manifest"
        run 0 list; contains '21+1-vendor'; contains '(manifest invalid)'
    done
    cp "$TEMP/valid-manifest" "$manifest"
    run 0 uninstall 21+1-vendor
    check 'three-line manifests preserve exact upstream rows and accept appended upstream/local columns offline'
    reset
    rm -f "$TEST_REMOVE_LOG"
}

inventory_checks() {
    local base before id
    reset; index; row 21+1 vendor; row 21+2 other; row 25+1 vendor
    run 0 install 21+1-vendor; run 0 install 21+2-other
    base=$XDG_DATA_HOME/jvm/jdks
    rm "$base/21+1-vendor/.jvm-manifest"
    printf 'broken manifest\n' > "$base/21+2-other/.jvm-manifest"
    before=$(< "$TEST_LOG")
    run 0 list; contains '21+1-vendor'; contains '(manifest missing)'; contains '(manifest invalid)'
    awk -F '\t+' 'NR>1 && (NF!=2 || $2 !~ /^\(manifest (missing|invalid)\)$/) {exit 1}' "$TEMP/out" || fail 'unknown metadata displayed for a bad manifest'
    run 0 list 21+1-vendor; contains '(manifest missing)'
    run 1 list 21; diagnostic 'No JDK found matching:'
    run 1 list vendor; diagnostic 'No JDK found matching:'
    run 1 list other-21; diagnostic 'No JDK found matching:'
    # An existing major alias cannot establish the target major without metadata.
    run 1 home 21; diagnostic 'default JDK for version 21 is unavailable'
    rm "$base/21"
    run 1 home 21; diagnostic 'No JDK found matching:'
    run 1 default -v 21 21+1-vendor; diagnostic 'cannot determine Java major'
    run 0 home 21+1-vendor; contains '/21+1-vendor'
    run 0 env 21+2-other; contains 'JAVA_HOME='; contains '/21+2-other'
    run 0 exec 21+1-vendor -- "$BASH_BIN" -c 'printf "%s\n" "$JAVA_HOME"'
    contains '/21+1-vendor'
    run 0 default 21+2-other; run 0 default; contains '21+2-other'
    run 0 home; contains '/jdks/default'
    run 0 default 21+1-vendor
    run 0 home 21+2-other; contains '/21+2-other'
    run 0 install 21+1-vendor; diagnostic 'Already installed'
    [ "$(< "$TEST_LOG")" = "$before" ] || fail 'exact bad-manifest selection accessed the network'
    # Folder names are identities too, including spaces and hidden folders.
    mv "$base/21+2-other" "$base/custom JDK"
    mkdir "$base/.manual" "$base/23+1-empty"
    printf 'ordinary file\n' > "$base/99+1-file"
    ln -s "$HOME" "$base/99+1-link"
    run 0 list; contains 'custom JDK'; contains '.manual'; contains '23+1-empty'
    awk -F '\t+' '$1==".manual" || $1=="23+1-empty" {if (NF!=2 || $2!="(invalid JDK)") exit 1}' "$TEMP/out" || fail 'invalid launcher layout did not take precedence over manifest status'
    [[ $(< "$TEMP/out") != *99+1-* ]] || fail 'file or directory link listed as an installation'
    run 1 uninstall 99+1-link; diagnostic 'No JDK found matching:'
    run 0 home 'custom JDK'; contains '/custom JDK'
    run 1 home 23+1-empty; diagnostic 'no usable java/javac launchers'
    mv "$base/21+1-vendor/bin/javac" "$TEMP/saved-javac"
    run 0 list 21+1-vendor; contains '(invalid JDK)'
    run 1 default 21+1-vendor; diagnostic 'no usable java/javac launchers'
    mv "$TEMP/saved-javac" "$base/21+1-vendor/bin/javac"
    run 0 uninstall .manual
    run 0 uninstall 23+1-empty
    # A failed move preserves a usable default even without its manifest.
    TEST_REMOVE_FAIL=1 run 1 uninstall 21+1-vendor
    diagnostic "couldn't uninstall 21+1-vendor"
    run 0 default; contains '21+1-vendor'
    run 0 install 25+1-vendor
    mv "$base/25+1-vendor/bin/javac" "$TEMP/saved-javac"
    run 0 list 25+1-vendor; contains '(invalid JDK)'
    run 1 list 25; diagnostic 'No JDK found matching:'
    mv "$TEMP/saved-javac" "$base/25+1-vendor/bin/javac"
    ln -s "$base/21+1-vendor" "$base/21" || fail 'cannot prepare manifestless major reference'
    run 0 uninstall 21+1-vendor
    [ ! -e "$base/21+1-vendor" ] && [ ! -L "$base/21" ] || fail 'bad-manifest uninstall left a directory or major reference'
    run 0 default; contains '25+1-vendor'
    run 0 default 'custom JDK'
    run 0 uninstall 'custom JDK'
    run 0 default; contains '25+1-vendor'
    check 'bad manifests remain visible and selectable by exact directory ID; short selectors and automatic defaults require metadata'
    reset; rm -f "$TEST_REMOVE_LOG"
}

execution_checks() {
    local cmd args before saved_archive=$TEST_ARCHIVE saved_umask
    reset; index; row 21+1 temurin; row 22+1 temurin
    for cmd in exec x; do
        PATH=/nonexistent run 0 "$cmd" --help
        PATH=/nonexistent run 2 "$cmd"
        [ "$(< "$TEMP/err")" = 'jvm: usage: jvm exec <selector> [--] <command> [args...]' ] || fail 'incomplete exec usage'
        PATH=/nonexistent run 2 "$cmd" -f 21
    done
    for cmd in available install uninstall default home env; do
        run 2 "$cmd" _
    done
    for cmd in shell s; do
        PATH=/nonexistent run 2 "$cmd" 21
        PATH=/nonexistent run 2 "$cmd" --help
    done
    for args in '21' '21 --' '_'; do
        PATH=/nonexistent run 2 exec $args
        [ "$(< "$TEMP/err")" = 'jvm: usage: jvm exec <selector> [--] <command> [args...]' ] || fail 'incomplete exec usage'
    done
    for cmd in exec x; do
        PATH=/nonexistent run 2 "$cmd" '' java
        PATH=/nonexistent run 2 "$cmd" 21 ''
        PATH=/nonexistent run 2 "$cmd" 21 -- ''
        PATH=/nonexistent run 2 "$cmd" _ --
        PATH=/nonexistent run 2 "$cmd" _ ''
    done
    [ ! -e "$TEST_LOG" ] && [ ! -e "$XDG_DATA_HOME/jvm" ] || fail 'execution usage had side effects'
    printf '#!%s\n' "$BASH_BIN" > "$TEMP/child with spaces"
    cat >> "$TEMP/child with spaces" <<'EOF'
[ "$JAVA_HOME" = "$TEST_EXPECT_HOME" ] || exit 91
[ "$PATH" = "$TEST_EXPECT_BIN:$TEST_BASE_PATH" ] || exit 92
[ "$(umask)" = "$TEST_EXPECT_UMASK" ] || exit 93
# Successful exec must clean private installation data before starting us.
for path in "$XDG_DATA_HOME/jvm/tmp"/jdk-* "$XDG_CACHE_HOME/jvm"/.discovery.*; do
    [ ! -d "$path" ] || exit 94
done
case "$1" in
    args)
        shift
        [ "$#" -eq 7 ] && [ "$1" = '' ] && [ "$2" = 'two words' ] &&
            [ "$3" = '$(touch "$HOME/should-not-exist")' ] && [ "$4" = '*' ] &&
            [ "$5" = -- ] && [ "$6" = --child-option ] && [ "$7" = 'line
break' ] || exit 95
        printf 'child output\n'; printf 'child diagnostic\n' >&2 ;;
    status) exit 37 ;;
    pin|global-pin)
        link=21; [ "$1" != global-pin ] || link=default
        rm "$XDG_DATA_HOME/jvm/jdks/$link" || exit 97
        ln -s "$XDG_DATA_HOME/jvm/jdks/22+1-temurin" "$XDG_DATA_HOME/jvm/jdks/$link" || exit 97
        [ "$JAVA_HOME" = "$TEST_EXPECT_HOME" ] && [ -d "$JAVA_HOME/bin" ] || exit 98 ;;
    pid) [ "$$" = "$TEST_EXPECT_PID" ] || exit 99 ;;
esac
EOF
    PATH=$ORIGINAL_PATH chmod +x "$TEMP/child with spaces"
    export TEST_EXPECT_HOME="$XDG_DATA_HOME/jvm/jdks/21+1-temurin"
    export TEST_EXPECT_BIN="$TEST_EXPECT_HOME/bin" TEST_BASE_PATH=$PATH
    saved_umask=$(umask); umask 022; export TEST_EXPECT_UMASK=$(umask)
    run 0 x 21 -- "$TEMP/child with spaces" args '' 'two words' '$(touch "$HOME/should-not-exist")' '*' -- --child-option $'line\nbreak'
    [ "$(< "$TEMP/out")" = 'child output' ] || fail 'exec child stdout'
    diagnostic 'child diagnostic'; diagnostic 'Successfully installed 21+1-temurin'
    [ ! -e "$HOME/should-not-exist" ] || fail 'command data evaluated'
    run 127 exec 21 -- -- "$TEMP/child with spaces"
    before=$(cat "$TEST_LOG")
    for cmd in exec x; do run 0 "$cmd" _ -- "$TEMP/child with spaces" status-check; done
    run 37 x _ "$TEMP/child with spaces" status
    mv "$XDG_DATA_HOME/jvm/jdks/default" "$TEMP/saved-default"
    run 1 exec _ "$TEMP/child with spaces" status-check
    diagnostic 'No JDK found matching: 25'
    dangling_link "$XDG_DATA_HOME/jvm/jdks/missing" "$XDG_DATA_HOME/jvm/jdks/default"
    run 1 x _ "$TEMP/child with spaces" status-check
    diagnostic 'default JDK is missing or unusable'
    rm "$XDG_DATA_HOME/jvm/jdks/default"
    ln -s "$HOME" "$XDG_DATA_HOME/jvm/jdks/default"
    run 1 exec _ "$TEMP/child with spaces" status-check
    diagnostic 'default JDK is missing or unusable'
    rm "$XDG_DATA_HOME/jvm/jdks/default"
    mv "$TEMP/saved-default" "$XDG_DATA_HOME/jvm/jdks/default"
    run 37 exec 21 "$TEMP/child with spaces" status
    [ ! -s "$TEMP/err" ] || fail 'exec status stderr'
    run 127 exec 21 -- nonexistent-jvm-test-command
    mkdir "$TEMP/not-executable"
    run 126 exec 21 -- "$TEMP/not-executable"
    "$BASH_BIN" -c 'export TEST_EXPECT_PID=$$; exec "$@"' bash "$BASH_BIN" "$ROOT/jvm" x 21 -- "$TEMP/child with spaces" pid || fail 'exec did not replace JVM process'
    [ "$(cat "$TEST_LOG")" = "$before" ] || fail 'local execution used networking'
    run 0 install 22
    run 0 x _ "$TEMP/child with spaces" global-pin
    run 0 default 21+1-temurin
    run 0 exec 21 -- "$TEMP/child with spaces" pin
    run 0 default; contains '21+1-temurin'
    rm "$XDG_DATA_HOME/jvm/jdks/21"
    run 0 exec temurin-21 "$TEMP/child with spaces" status-check
    index; row 21+2 other
    run 0 install other-21
    rm "$XDG_DATA_HOME/jvm/jdks/21"
    before=$(cat "$TEST_LOG")
    run 1 x 21 -- "$TEMP/child with spaces" status
    diagnostic 'Multiple JDKs match'
    [ "$(cat "$TEST_LOG")" = "$before" ] || fail 'ambiguous execution used networking'
    run 0 exec 21+1-temurin -- "$TEMP/child with spaces" status-check
    # Conversion is shared with env: native JAVA_HOME, POSIX PATH entry.
    reset; TEST_SYSTEM=MINGW64_NT-10.0; TEST_OS=windows
    TEST_ARCHIVE=$ROOT/tests/fixtures/archives/windows.zip
    index; row 25+1 temurin zip
    mv "$TOOLS/cygpath" "$TEMP/cygpath"
    printf '#!%s\ncase "$1" in -m) printf "C:%%s\\n" "$2" ;; *) printf "%%s\\n" "$2" ;; esac\n' "$BASH_BIN" > "$TOOLS/cygpath"
    PATH=$ORIGINAL_PATH chmod +x "$TOOLS/cygpath"
    export TEST_EXPECT_HOME="C:$XDG_DATA_HOME/jvm/jdks/25+1-temurin"
    export TEST_EXPECT_BIN="$XDG_DATA_HOME/jvm/jdks/25+1-temurin/bin"
    run 0 x 25 -- "$TEMP/child with spaces" status-check
    run 0 exec _ "$TEMP/child with spaces" status-check
    mv "$TEMP/cygpath" "$TOOLS/cygpath"
    TEST_SYSTEM=Linux; TEST_OS=linux; TEST_ARCHIVE=$saved_archive
    reset; index; row 26+1 temurin
    export TEST_EXPECT_HOME="$XDG_DATA_HOME/jvm/jdks/26+1-temurin"
    export TEST_EXPECT_BIN="$TEST_EXPECT_HOME/bin"
    run 0 x 26 -- "$TEMP/child with spaces" status-check
    diagnostic 'Successfully installed 26+1-temurin'
    run 0 default; contains '26+1-temurin'
    index; row 27+1 temurin
    TEST_ARTIFACT_STATUS=503 run 1 x 27 -- "$TEMP/child with spaces" status-check
    diagnostic 'artifact transfer failed'
    run 0 default; contains '26+1-temurin'
    umask "$saved_umask"
    check 'exec selectors, install-on-demand cleanup, physical homes, literal arguments, streams, status, removed shell command and simulated Windows paths'
}

flag_alias_checks() {
    local cmd args before saved_data saved_archive
    reset; index; row 21+1 temurin; row 22+1 other-vendor; row 23+1 temurin
    # All parsing failures precede even host detection, with no utilities on PATH.
    for cmd in available list install uninstall default home env a l i u d h e; do
        for args in '-x 21' '21 -x' '21 extra' '--help 21' '-d -d 21'; do
            PATH=/nonexistent run 2 "$cmd" $args
        done
        PATH=/nonexistent run 2 "$cmd" ''
    done
    for cmd in available list uninstall a l u; do
        PATH=/nonexistent run 2 "$cmd" 21 -d
    done
    for cmd in default home env d h e; do
        PATH=/nonexistent run 2 "$cmd" -d 21
    done
    [ ! -e "$TEST_LOG" ] && [ ! -e "$XDG_DATA_HOME/jvm" ] || fail 'invalid usage had side effects'
    run 0 a temurin-21; contains '21+1-temurin'
    run 0 i -d 21
    [ ! -s "$TEMP/out" ] || fail 'install alias stdout'
    diagnostic 'Successfully installed 21+1-temurin'
    run 0 d; contains '21+1-temurin'
    run 0 install 22+1-other-vendor -d
    run 0 default; contains '22+1-other-vendor'
    run 0 i 21+1-temurin -d; diagnostic 'Already installed 21+1-temurin'
    run 0 default; contains '21+1-temurin'
    run 0 l 21; contains '21+1-temurin'
    before=$(cat "$TEST_LOG")
    rm "$XDG_DATA_HOME/jvm/jdks/22"
    for cmd in home h env e default d; do
        run 0 "$cmd" 22
        case "$cmd" in
            home|h) [ "$(< "$TEMP/out")" = "$XDG_DATA_HOME/jvm/jdks/22+1-other-vendor" ] || fail 'local home' ;;
            env|e) contains "# Use: eval \"\$('${ROOT}/jvm' $cmd 22)\""; contains 'export JAVA_HOME=' ;;
        esac
        run 0 "$cmd" 21
    done
    [ "$(cat "$TEST_LOG")" = "$before" ] || fail 'local selection used networking'
    run 0 home 23
    [ "$(< "$TEMP/out")" = "$XDG_DATA_HOME/jvm/jdks/23" ] || fail 'installed home stdout'
    diagnostic 'Installing 23+1-temurin...'
    run 0 default; contains '21+1-temurin'
    run 0 install 23+1-temurin -d
    # Replacement failure preserves a usable old default; the new JDK can remain.
    index; row 24+1 temurin
    TEST_DEFAULT_FAIL=1 run 1 install -d 24
    diagnostic 'cannot replace the default JDK link'
    [ -f "$XDG_DATA_HOME/jvm/jdks/24+1-temurin/.jvm-manifest" ] || fail 'successful installation lost'
    TEST_DEFAULT_FAIL=1 run 1 default 24
    TEST_DEFAULT_INTERRUPT=1 run 1 i -d 21+1-temurin
    run 0 default; contains '23+1-temurin'
    index; row 25+1 temurin
    TEST_ARTIFACT_STATUS=503 run 1 i -d 25
    TEST_ARTIFACT_STATUS=503 run 1 h 25
    run 0 default; contains '23+1-temurin'
    # Exact IDs remain usable with no downloaders or cache, including install -d.
    rm -rf -- "$XDG_CACHE_HOME/jvm"
    mv "$TOOLS/curl" "$TEMP/curl"; mv "$TOOLS/wget" "$TEMP/wget"
    run 0 i 21+1-temurin -d
    run 0 h 21+1-temurin
    run 0 e 21+1-temurin
    run 0 d 21+1-temurin
    run 0 u 22+1-other-vendor; diagnostic 'Successfully uninstalled 22+1-other-vendor'
    mv "$TEMP/curl" "$TOOLS/curl"; mv "$TEMP/wget" "$TOOLS/wget"
    # A broad major with multiple local matches must never fall through to install.
    index; row 21+2 other-vendor
    run 0 install 21+2-other-vendor
    before=$(cat "$TEST_LOG")
    for cmd in default home env; do
        run 0 "$cmd" 21
    done
    rm "$XDG_DATA_HOME/jvm/jdks/21"
    for cmd in default home env; do
        run 1 "$cmd" 21; diagnostic 'Multiple JDKs match'
        run 2 "$cmd" ../21
    done
    [ "$(cat "$TEST_LOG")" = "$before" ] || fail 'ambiguity/validation used networking'
    # Storage and utility failures are not misses.
    saved_data=$XDG_DATA_HOME; XDG_DATA_HOME=$TEMP/invalid-data
    mkdir -p "$XDG_DATA_HOME"; printf 'blocked' > "$XDG_DATA_HOME/jvm"
    for cmd in default home env; do run 1 "$cmd" 26; done
    XDG_DATA_HOME=$TEMP/invalid-root
    printf 'blocked' > "$XDG_DATA_HOME"
    for cmd in default home env; do run 1 "$cmd" 26; done
    XDG_DATA_HOME=$saved_data
    mv "$TOOLS/awk" "$TEMP/awk"
    printf '#!%s\nexit 2\n' "$BASH_BIN" > "$TOOLS/awk"
    for cmd in default home env; do run 1 "$cmd" 26; done
    mv "$TEMP/awk" "$TOOLS/awk"
    [ "$(cat "$TEST_LOG")" = "$before" ] || fail 'operational failure used networking'
    # No existing default: both output commands retain first-install initialization.
    for cmd in home env default; do
        reset; index; row 27+1 temurin; row 27+1 other-vendor
        run 0 "$cmd" 27
        diagnostic 'Successfully installed 27+1-temurin'
        run 0 default; contains '27+1-temurin'
        [ ! -e "$XDG_DATA_HOME/jvm/jdks/27+1-other-vendor" ] || fail 'bare install fallback changed'
    done
    reset; index; row 29+1 other-vendor
    run 0 install other-vendor-29
    mkdir -p "$TEMP/competitor"
    mv "$XDG_DATA_HOME/jvm/jdks/29+1-other-vendor" "$TEMP/competitor/"
    rm "$XDG_DATA_HOME/jvm/jdks/29"
    index; row 29+1 temurin
    TEST_EXTRA_LOCAL=$TEMP/competitor/29+1-other-vendor run 0 env 29
    contains "export JAVA_HOME='$XDG_DATA_HOME/jvm/jdks/29'"
    run 0 default; contains '29+1-other-vendor'
    run 0 env 29; contains "export JAVA_HOME='$XDG_DATA_HOME/jvm/jdks/29'"
    # Simulated Windows paths still pass through the normal conversion and quoting.
    reset; TEST_SYSTEM=MINGW64_NT-10.0; TEST_OS=windows
    saved_archive=$TEST_ARCHIVE; TEST_ARCHIVE=$ROOT/tests/fixtures/archives/windows.zip
    index; row 28+1 temurin zip
    run 0 i -d 28
    mv "$TOOLS/cygpath" "$TEMP/cygpath"
    printf '#!%s\ncase "$1" in -m) printf "C:/test home/%%s\\n" "${2##*/}" ;; *) printf "%%s\\n" "$2" ;; esac\n' "$BASH_BIN" > "$TOOLS/cygpath"
    PATH=$ORIGINAL_PATH chmod +x "$TOOLS/cygpath"
    run 0 h 28
    [ "$(< "$TEMP/out")" = "$XDG_DATA_HOME/jvm/jdks/28" ] || fail 'Windows home must remain POSIX'
    run 0 e 28; contains "export JAVA_HOME='C:/test home/28'"
    mv "$TEMP/cygpath" "$TOOLS/cygpath"
    TEST_SYSTEM=Linux; TEST_OS=linux; TEST_ARCHIVE=$saved_archive
    reset
    check 'flags, aliases, offline-first resolution, exact IDs, failure preservation and output streams'
}

uninstall_checks() {
    reset; index
    run 2 uninstall; run 2 uninstall ''; run 2 uninstall 21 extra
    run 2 uninstall ../21; run 2 uninstall vendor
    run 1 uninstall 21; diagnostic 'No JDK found matching: 21'
    [ ! -e "$XDG_DATA_HOME/jvm" ] || fail 'unmatched removal created storage'
    row 21+1 temurin; row 21+2 temurin; row 21+1 other-vendor
    row 1.8.0_99-b09 old-vendor
    for id in 21+1-temurin 21+2-temurin 21+1-other-vendor 8-1.8.0_99-b09-old-vendor; do run 0 install "$id"; done
    rm "$XDG_DATA_HOME/jvm/jdks/default"
    printf 'keep\n' > "$XDG_DATA_HOME/jvm/jdks/default"
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
    run 0 list 8; contains '8-1.8.0_99-b09-old-vendor'
    run 1 list 999; diagnostic 'No JDK found matching: 999'
    run 1 list missing-vendor; diagnostic 'No JDK found matching: missing-vendor'
    run 2 list ../21; run 2 list 01; run 2 list ''; run 2 list 21 extra
    [ ! -e "$XDG_CACHE_HOME/jvm" ] || fail 'filtered listing accessed cache'
    check 'offline list filters return all matching IDs, majors, distros and distro-majors'
    run 1 uninstall 21; diagnostic 'Multiple JDKs match, try again using one of the following IDs:'; diagnostic '21+1-temurin'; diagnostic '21+2-temurin'; diagnostic '21+1-other-vendor'
    diagnostic 'DEFAULT'
    awk -F '\t+' 'NR==2 && $3!="VERSION" {exit 1} NR>2 && $3!="21+99" {exit 1}' "$TEMP/err" || fail 'local ambiguity VERSION must show java_version'
    run 1 uninstall temurin-21; diagnostic 'Multiple JDKs match, try again using one of the following IDs:'
    diagnostic 'DEFAULT'
    [ ! -e "$TEST_REMOVE_LOG" ] || fail 'ambiguous removal moved a JDK'
    TEST_REMOVE_FAIL=1
    run 1 uninstall 21+1-temurin; diagnostic "couldn't uninstall 21+1-temurin"
    [[ $(< "$TEMP/err") != *'might be in use'* ]] || fail 'Windows hint on Linux'
    run 0 list; contains '21+1-temurin'
    TEST_REMOVE_FAIL=0
    run 0 uninstall 21+1-temurin; diagnostic 'Successfully uninstalled 21+1-temurin'
    run 1 uninstall 21; diagnostic 'Multiple JDKs match, try again using one of the following IDs:'; diagnostic '21+2-temurin'; diagnostic '21+1-other-vendor'
    run 0 uninstall temurin-21; diagnostic 'Successfully uninstalled 21+2-temurin'
    run 0 uninstall 8; diagnostic 'Successfully uninstalled 8-1.8.0_99-b09-old-vendor'
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
    [ "$(< "$XDG_DATA_HOME/jvm/jdks/default")" = keep ] || fail 'uninstall changed default'
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

default_checks() {
    # Every existing default lifecycle/flag check must ignore malformed settings,
    # including installs reached through default's shared helper.
    mkdir -p "$XDG_CONFIG_HOME/jvm"
    printf 'unknown=project\n' > .jvmrc
    printf 'java=invalid\n' > "$XDG_CONFIG_HOME/jvm/config"
    reset; index
    run 0 default; contains 'No JDK currently set as the default'
    run 2 default ''; run 2 default vendor; run 2 default 21 extra
    row 21+1 vendor; row 21+2 vendor; row 21+1 other
    row 23+1 vendor; row 25+1 vendor; row 17+1 vendor; row 1.8.0_99 old
    run 0 install 21+1-vendor
    diagnostic 'Default JDK set to: 21+1-vendor'
    run 0 default; contains '21+1-vendor'
    run 0 list; contains 'DEFAULT'; contains 'global,21'
    rm "$XDG_DATA_HOME/jvm/jdks/default" "$XDG_DATA_HOME/jvm/jdks/21"
    run 0 default
    [ "$(< "$TEMP/out")" = 'No JDK currently set as the default' ] || fail 'wrong missing-default message with an installed JDK'
    [ ! -s "$TEMP/err" ] || fail 'missing-default query wrote a diagnostic'
    run 0 list; contains '21+1-vendor'
    [ ! -e "$XDG_DATA_HOME/jvm/jdks/default" ] && [ ! -e "$XDG_DATA_HOME/jvm/jdks/21" ] || fail 'read-only query created default links'
    run 0 install 21+1-vendor
    for id in 21+2-vendor 21+1-other 23+1-vendor 25+1-vendor 17+1-vendor 8-1.8.0_99-old; do
        run 0 install "$id"
        [[ $(< "$TEMP/err") != *'Default JDK set to:'* ]] || fail 'unchanged default announced'
    done
    run 0 default -v 21; contains '21+1-vendor'
    run 0 default -v 23; contains '23+1-vendor'
    run 0 default -v 21 21+2-vendor
    run 0 default; contains '21+1-vendor'
    run 0 list; contains 'global'; contains '21'
    run 1 default -v 21 23+1-vendor; diagnostic 'expected 21'
    index; row 26+1 temurin
    before=$(count_downloads)
    run 1 default -v 21 26; diagnostic 'expected 21'
    [ "$(count_downloads)" = "$before" ] || fail 'major mismatch downloaded an artifact'
    [ ! -e "$XDG_DATA_HOME/jvm/jdks/26+1-temurin" ] || fail 'major mismatch installed an artifact'
    index
    row 21+1 vendor; row 21+2 vendor; row 21+1 other
    row 23+1 vendor; row 25+1 vendor; row 17+1 vendor; row 1.8.0_99 old
    run 0 default -v 21; contains '21+2-vendor'
    run 0 default -v 21 21+2-vendor
    run 0 default; contains '21+1-vendor'
    run 2 default -v; run 2 default -v 0; run 2 default -v 21 -v 21
    run 0 default -v 21 21+1-vendor
    TEST_DEFAULT_FAIL=1 run 1 default -v 21 21+2-vendor
    run 0 default -v 21; contains '21+1-vendor'
    run 0 default; contains '21+1-vendor'
    rm "$XDG_DATA_HOME/jvm/jdks/21"
    TEST_DEFAULT_GATE=$TEMP/major-gate TEST_DEFAULT_LINK=21
    mkdir "$TEST_DEFAULT_GATE"
    TEST_DEFAULT_ROLE=first "$BASH_BIN" "$ROOT/jvm" install 21+1-vendor > "$TEMP/first.out" 2> "$TEMP/first.err" & first=$!
    TEST_DEFAULT_ROLE=second "$BASH_BIN" "$ROOT/jvm" install 21+2-vendor > "$TEMP/second.out" 2> "$TEMP/second.err" & second=$!
    for attempt in {1..200}; do
        if [ -e "$TEST_DEFAULT_GATE/first.ready" ] && [ -e "$TEST_DEFAULT_GATE/second.ready" ]; then break; fi
        sleep 0.05
    done
    [ -e "$TEST_DEFAULT_GATE/first.ready" ] && [ -e "$TEST_DEFAULT_GATE/second.ready" ] || fail 'major initializers did not reach link creation'
    : > "$TEST_DEFAULT_GATE/first.release"; wait "$first" || fail 'first major initializer failed'; first=
    : > "$TEST_DEFAULT_GATE/second.release"; wait "$second" || fail 'second major initializer failed'; second=
    TEST_DEFAULT_GATE= TEST_DEFAULT_LINK=default
    run 0 default -v 21; contains '21+1-vendor'
    run 0 default; contains '21+1-vendor'
    rm "$XDG_DATA_HOME/jvm/jdks/default"
    TEST_DEFAULT_GATE=$TEMP/default-gate
    mkdir "$TEST_DEFAULT_GATE"
    TEST_DEFAULT_ROLE=first "$BASH_BIN" "$ROOT/jvm" install 21+1-vendor > "$TEMP/first.out" 2> "$TEMP/first.err" & first=$!
    TEST_DEFAULT_ROLE=second "$BASH_BIN" "$ROOT/jvm" install 17+1-vendor > "$TEMP/second.out" 2> "$TEMP/second.err" & second=$!
    for attempt in {1..200}; do
        if [ -e "$TEST_DEFAULT_GATE/first.ready" ] && [ -e "$TEST_DEFAULT_GATE/second.ready" ]; then break; fi
        sleep 0.05
    done
    [ -e "$TEST_DEFAULT_GATE/first.ready" ] && [ -e "$TEST_DEFAULT_GATE/second.ready" ] || fail 'initializers did not reach link creation'
    : > "$TEST_DEFAULT_GATE/first.release"
    wait "$first" || fail 'first default initializer failed'; first=
    : > "$TEST_DEFAULT_GATE/second.release"
    wait "$second" || fail 'second default initializer failed'; second=
    TEST_DEFAULT_GATE=
    [ ! -e "$XDG_DATA_HOME/jvm/jdks/21+1-vendor/17+1-vendor" ] || fail 'losing initializer created a nested link'
    [ "$(< "$TEMP/second.err")" = 'Already installed 17+1-vendor' ] || fail 'unexpected losing initializer message'
    [ ! -s "$TEMP/first.out" ] && [ ! -s "$TEMP/second.out" ] || fail 'initializers wrote to stdout'
    [[ $(< "$TEMP/first.err") = *'Default JDK set to: 21+1-vendor'* ]] || fail 'initializer omitted confirmation'
    [[ $(< "$TEMP/second.err") != *'Default JDK set to:'* ]] || fail 'losing initializer announced selection'
    run 0 default; contains '21+1-vendor'
    TEST_DEFAULT_FAIL=1
    run 1 default 17; diagnostic 'cannot replace'
    TEST_DEFAULT_FAIL=0
    run 0 default; contains '21+1-vendor'
    TEST_DEFAULT_INTERRUPT=1
    run 1 default 17
    TEST_DEFAULT_INTERRUPT=0
    run 0 default; contains '21+1-vendor'
    TEST_DEFAULT_FAIL=2
    run 1 default 17
    TEST_DEFAULT_FAIL=0
    run 0 default; contains '21+1-vendor'
    TEST_DEFAULT_INTERRUPT=2
    run 1 default 17
    TEST_DEFAULT_INTERRUPT=0
    run 0 default; contains '21+1-vendor'
    mv "$TOOLS/readlink" "$TEMP/readlink"
    run 1 uninstall 21+1-vendor; diagnostic 'required utility missing: readlink'
    [ -d "$XDG_DATA_HOME/jvm/jdks/21+1-vendor" ] || fail 'uninstall ignored unreadable default'
    mv "$TEMP/readlink" "$TOOLS/readlink"
    run 0 default; contains '21+1-vendor'
    mv "$TOOLS/curl" "$TEMP/curl"; mv "$TOOLS/wget" "$TEMP/wget"
    rm -rf -- "$XDG_CACHE_HOME/jvm"
    run 0 default 21; diagnostic 'Default JDK set to: 21+1-vendor'
    rm "$XDG_DATA_HOME/jvm/jdks/21"
    run 1 default 21; diagnostic 'Multiple JDKs match'
    run 0 install 21+1-vendor
    run 0 default vendor-17
    [ "$(< "$TEMP/err")" = 'Default JDK set to: 17+1-vendor' ] || fail 'wrong default confirmation'
    [ ! -s "$TEMP/out" ] || fail 'default selection wrote to stdout'
    run 0 default; contains '17+1-vendor'
    run 0 default 21+1-vendor
    TEST_DEFAULT_FAIL_MAJOR=1 run 1 uninstall 21+1-vendor
    [ -d "$XDG_DATA_HOME/jvm/jdks/21+1-vendor" ] || fail 'major-link failure removed the JDK'
    run 0 default; contains '21+1-vendor'
    run 0 default -v 21; contains '21+1-vendor'
    TEST_REMOVE_FAIL=1
    run 1 uninstall 21+1-vendor
    run 0 default; contains '21+1-vendor'
    TEST_REMOVE_FAIL=0
    run 0 uninstall 21+1-vendor
    diagnostic 'Default JDK set to: 21+1-other'
    run 0 default; contains '21+1-other'
    run 0 default -v 21; contains '21+1-other'
    run 0 uninstall 21+1-other
    run 0 default; contains '21+2-vendor'
    run 0 uninstall 21+2-vendor
    run 0 default; contains '23+1-vendor'
    run 0 default -v 21; contains 'No JDK currently set as the default for version 21'
    run 0 uninstall 23+1-vendor
    run 0 default; contains '25+1-vendor'
    run 0 uninstall 25+1-vendor
    run 0 default; contains '17+1-vendor'
    run 0 uninstall 17+1-vendor
    run 0 default; contains '8-1.8.0_99-old'
    run 0 uninstall 8
    diagnostic 'No JDK currently set as the default'
    run 0 default; contains 'No JDK currently set as the default'
    [ ! -e "$XDG_DATA_HOME/jvm/jdks/default" ] && [ ! -L "$XDG_DATA_HOME/jvm/jdks/default" ] || fail 'last default link remains'
    [ ! -e "$XDG_CACHE_HOME/jvm" ] || fail 'local default operations accessed cache'
    # A genuine miss attempts installation and fails without a downloader.
    run 1 default 99; diagnostic 'install curl or wget to fetch metadata'
    run 0 default; contains 'No JDK currently set as the default'
    mv "$TEMP/curl" "$TOOLS/curl"; mv "$TEMP/wget" "$TOOLS/wget"
    mv "$TOOLS/ln" "$TEMP/ln"
    run 1 install 17+1-vendor; diagnostic 'JDK installed, but Java 17 default selection failed'
    [ -f "$XDG_DATA_HOME/jvm/jdks/17+1-vendor/.jvm-manifest" ] || fail 'default failure removed installed JDK'
    mv "$TEMP/ln" "$TOOLS/ln"
    run 0 install 17+1-vendor
    run 0 default; contains '17+1-vendor'
    rm "$XDG_DATA_HOME/jvm/jdks/default"
    printf 'unrelated\n' > "$XDG_DATA_HOME/jvm/jdks/default"
    run 1 default 17; diagnostic 'not a managed link'
    [ "$(< "$XDG_DATA_HOME/jvm/jdks/default")" = unrelated ] || fail 'default overwrote unrelated data'
    check 'persistent defaults, first install, offline selection, failed/interrupted replacement, failed removal rollback and complete fallback order'
    rm .jvmrc "$XDG_CONFIG_HOME/jvm/config"
    rmdir "$XDG_CONFIG_HOME/jvm" "$XDG_CONFIG_HOME"
    reset
}

java_major_checks() {
    local base before
    reset; index
    row 22.3.1+java19 graalvm tar.gz "$TEST_ARCHIVE" 19
    row 190.1 boundary tar.gz "$TEST_ARCHIVE" 19
    row 19-22.3.2+java19 graalvm tar.gz "$TEST_ARCHIVE" 19
    row 22.0.2 temurin tar.gz "$TEST_ARCHIVE" 21
    run 0 available graalvm-19; contains '19-22.3.1+java19-graalvm'; contains '19-22.3.2+java19-graalvm'
    run 1 available graalvm-22; diagnostic 'No JDK found matching:'
    run 0 available boundary-19; contains '19-190.1-boundary'
    run 0 install 19-22.3.1+java19-graalvm
    base=$XDG_DATA_HOME/jvm/jdks
    [ "$base/19" -ef "$base/19-22.3.1+java19-graalvm" ] || fail 'vendor major used for default initialization'
    [ ! -e "$base/22" ] || fail 'vendor-major reference created'
    run 0 install 21; diagnostic 'Successfully installed 21-22.0.2-temurin'
    [ "$base/21" -ef "$base/21-22.0.2-temurin" ] || fail 'bare install used vendor major'
    run 0 default -v 19 19-22.3.2+java19-graalvm
    [ "$base/19" -ef "$base/19-22.3.2+java19-graalvm" ] || fail 'prefixed version received duplicate prefix'
    before=$(< "$TEST_LOG")
    mv "$TOOLS/curl" "$TEMP/curl"; mv "$TOOLS/wget" "$TEMP/wget"
    rm -rf -- "$XDG_CACHE_HOME/jvm"
    run 0 list 19; contains '19-22.3.1+java19-graalvm'; contains '19-22.3.2+java19-graalvm'; contains '19+99'
    [[ $(< "$TEMP/out") != *temurin* ]] || fail 'offline major filter used vendor version'
    run 1 list 22; diagnostic 'No JDK found matching:'
    run 0 home 19; contains '/jdks/19'
    run 1 home graalvm-19; diagnostic 'Multiple JDKs match'
    run 0 default -v 19; contains '19-22.3.2+java19-graalvm'
    run 0 default -v 19 19-22.3.1+java19-graalvm
    run 1 default -v 22 19-22.3.1+java19-graalvm; diagnostic 'Java major 19, expected 22'
    run 0 env 19; contains '/jdks/19'
    run 0 exec 19 -- "$BASH_BIN" -c 'printf "%s\n" "$JAVA_HOME"'; contains '/19-22.3.1+java19-graalvm'
    run 0 default 19-22.3.1+java19-graalvm
    run 0 uninstall 19-22.3.1+java19-graalvm
    [ "$base/19" -ef "$base/19-22.3.2+java19-graalvm" ] &&
        [ "$base/default" -ef "$base/19-22.3.2+java19-graalvm" ] || fail 'same-Java-major replacement failed'
    run 0 home graalvm-19; contains '/19-22.3.2+java19-graalvm'
    run 0 uninstall graalvm-19
    [ ! -L "$base/19" ] && [ "$base/default" -ef "$base/21-22.0.2-temurin" ] || fail 'Java-major fallback failed'
    [ "$(< "$TEST_LOG")" = "$before" ] || fail 'offline Java-major selection accessed network'
    mv "$TEMP/curl" "$TOOLS/curl"; mv "$TEMP/wget" "$TOOLS/wget"
    reset
    check 'Java majors drive discovery, installation, offline selection, references and replacement; IDs retain vendor versions'
}

ea_checks() {
    local base before selector command
    reset; index; row 28+1-ea zulu; row 28+2-ea zulu
    awk 'BEGIN {FS=OFS="\t"} NR>1 {$1="ea"} {print}' "$TEST_FIXTURE" > "$TEMP/ea-index"
    mv "$TEMP/ea-index" "$TEST_FIXTURE"
    run 1 install zulu-28; diagnostic 'Multiple JDKs match'
    run 0 install 28+1-ea-zulu
    base=$XDG_DATA_HOME/jvm/jdks
    awk -F '\t' 'NR==2 && $1!="ea" {exit 1}' "$base/28+1-ea-zulu/.jvm-manifest" || fail 'EA release type not preserved'
    run 0 list zulu-28; contains '28+1-ea-zulu'
    [[ $(< "$TEMP/out") != *'manifest invalid'* ]] || fail 'EA manifest rejected'
    run 0 default -v 28; contains '28+1-ea-zulu'
    before=$(< "$TEST_LOG")
    rm -rf -- "$XDG_CACHE_HOME/jvm"
    for selector in 28 zulu-28 28+1-ea-zulu 28+ zulu-28..28; do
        run 0 home "$selector"; contains '/jdks/28'
        run 0 env "$selector"; contains 'JAVA_HOME='; contains '/jdks/28'
        run 0 x "$selector" -- "$BASH_BIN" -c 'printf "%s\n" "$JAVA_HOME"'
        contains '/28+1-ea-zulu'
    done
    run 0 default zulu-28
    run 0 default -v 28 zulu-28
    [ "$(< "$TEST_LOG")" = "$before" ] || fail 'installed EA selection used network'
    run 0 install 28+2-ea-zulu
    run 0 uninstall 28+1-ea-zulu
    [ "$base/28" -ef "$base/28+2-ea-zulu" ] && [ "$base/default" -ef "$base/28+2-ea-zulu" ] || fail 'EA default replacement'
    run 0 uninstall zulu-28
    [ ! -L "$base/28" ] && [ ! -L "$base/default" ] || fail 'EA default removal'
    check 'EA manifests, offline exact/major/distro/range selection, exec and default lifecycle'

    for command in home env default exec; do
        reset; index; row 28+1-ea zulu
        awk 'BEGIN {FS=OFS="\t"} NR>1 {$1="ea"} {print}' "$TEST_FIXTURE" > "$TEMP/ea-index"
        mv "$TEMP/ea-index" "$TEST_FIXTURE"
        if [ "$command" = exec ]; then
            run 0 exec zulu-28 -- "$BASH_BIN" -c 'printf "%s\n" "$JAVA_HOME"'
            contains '/28+1-ea-zulu'
        else
            run 0 "$command" zulu-28
        fi
        [ -d "$base/28+1-ea-zulu" ] || fail 'EA install-on-demand missing'
        run 0 list zulu-28; contains '28+1-ea-zulu'
        [[ $(< "$TEMP/out") != *'manifest invalid'* ]] || fail 'installed EA unusable offline'
    done
    reset; index; row 27+1 temurin; row 28+1-ea temurin
    awk 'BEGIN {FS=OFS="\t"} NR==3 {$1="ea"} {print}' "$TEST_FIXTURE" > "$TEMP/ea-index"
    mv "$TEMP/ea-index" "$TEST_FIXTURE"
    run 0 install 27+; diagnostic 'Successfully installed 28+1-ea-temurin'
    run 0 home 27+; contains '/28+1-ea-temurin'
    check 'EA install-on-demand for home/env/default/exec and highest-major GA/EA ranges'
    reset
}

type_checks() {
    local before command selector
    reset; index
    row 21+1 vendor; row 21+2 vendor; row 21+3 vendor; row 21+4 vendor
    row 21+3 vendor zip "$ROOT/tests/fixtures/archives/jdk.zip"
    awk 'BEGIN {FS=OFS="\t"}
        NR==2 {$15="[feat,feat2]"}
        NR==4 || NR==5 || NR==6 {$1="ea"}
        NR==4 {$15="[feat,feat2]"}
        NR==6 {$15="[ignored-duplicate]"}
        {print}' "$TEST_FIXTURE" > "$TEMP/typed-index"
    mv "$TEMP/typed-index" "$TEST_FIXTURE"
    run 0 available
    awk -F '\t+' 'NR==1 && (NF!=4 || $4!="JVM") {exit 1}
        END {if(NR!=5) exit 1}' "$TEMP/out" || fail 'ordinary discovery must include GA and EA without TYPE'
    before=$(< "$TEST_LOG")
    cp "$TEMP/out" "$TEMP/without-type"
    run 0 available -t
    [ "$(< "$TEST_LOG")" = "$before" ] || fail '-t triggered another index fetch'
    awk -F '\t+' 'NR==1 && (NF!=5 || $5!="TYPE") {exit 1}
        NR==2 && ($1!="21+1-vendor" || $5!="feat,feat2") {exit 1}
        NR==3 && ($1!="21+2-vendor" || $5!="") {exit 1}
        NR==4 && ($1!="21+3-vendor" || $5!="ea,feat,feat2") {exit 1}
        NR==5 && ($1!="21+4-vendor" || $5!="ea") {exit 1}
        END {if(NR!=5) exit 1}' "$TEMP/out" || fail 'opt-in TYPE/EA/deduplication'
    # Check TYPE alignment, including its empty GA cell and long first columns.
    awk 'function expanded(s, i,c,out) {
        out=""; for(i=1;i<=length(s);i++) {c=substr(s,i,1)
            if(c=="\t") {do {out=out " "} while(length(out)%8)} else out=out c}
        return out}
        NR==1 {column=index(expanded($0),"TYPE"); next}
        NR==2 || NR==4 || NR==5 {line=expanded($0); value=(NR==2 ? "feat,feat2" : (NR==4 ? "ea,feat,feat2" : "ea")); if(substr(line,column)!=value) exit 1}
        NR==3 {if(length(expanded($0))!=column-1) exit 1}' "$TEMP/out" || fail 'TYPE alignment'
    awk -F '\t+' 'NR==FNR {expected[FNR]=$1 FS $2 FS $3 FS $4; next}
        expected[FNR]!=($1 FS $2 FS $3 FS $4) {exit 1}' "$TEMP/without-type" "$TEMP/out" || fail '-t changed selected rows'
    [[ $(< "$TEST_LOG") = *'/metadata/all/linux/x86_64/jdk-latest.tsv'* ]] || fail 'wrong all-release index'
    before=$(< "$TEST_LOG")
    for selector in 21 vendor vendor-21 21+ 21..21 vendor-21+; do
        run 0 a "$selector" -t; contains 'ea,feat,feat2'
    done
    [ "$(< "$TEST_LOG")" = "$before" ] || fail 'selectors did not share the all-release cache'
    run 0 available
    [ "$(< "$TEST_LOG")" = "$before" ] || fail '-t changed the shared cache'
    run 2 available -t -t; diagnostic 'duplicate flag'
    run 2 available -t ''
    run 2 available -t 25..21
    run 1 available -t 22; diagnostic 'No JDK found matching'
    run 2 available -a; diagnostic 'unsupported flag'
    for command in list install uninstall default home env; do
        run 2 "$command" -t
        diagnostic 'unsupported flag'
    done
    run 1 install vendor-21
    [[ $(< "$TEMP/err") != *TYPE* ]] || fail 'TYPE in remote ambiguity'
    diagnostic '21+3-vendor'; diagnostic '21+4-vendor'
    run 0 install 21+1-vendor; run 0 install 21+2-vendor
    before=$(< "$TEST_LOG")
    rm -rf -- "$XDG_CACHE_HOME/jvm"
    run 0 list
    awk -F '\t+' 'NR==1 && (NF!=5 || $5!="DEFAULT") {exit 1}' "$TEMP/out" || fail 'TYPE in installed listing'
    run 1 home vendor-21
    [[ $(< "$TEMP/err") != *TYPE* ]] || fail 'TYPE in local ambiguity'
    [ "$(< "$TEST_LOG")" = "$before" ] || fail 'local listings used networking'
    check 'available -t EA/TYPE formatting, selectors, shared cache and unchanged other listings'
    reset
}

range_checks() {
    local base before selector command id
    reset; index
    # Upstream order, vendor version and Java major deliberately disagree.
    row 99.0.1 temurin tar.gz "$TEST_ARCHIVE" 21
    row 25+9 temurin
    row 26+1 other-vendor
    row 25+10 temurin
    row 22.3.1+java17 graalvm-community tar.gz "$TEST_ARCHIVE" 17
    row 1.8.0_99-b09 old-vendor
    row 25+1 other-vendor
    run 0 available 21..25
    awk -F '\t+' 'NR>1 {id[++n]=$1} END {if(n!=4 || id[1]!="21-99.0.1-temurin" || id[2]!="25+9-temurin" || id[3]!="25+10-temurin" || id[4]!="25+1-other-vendor") exit 1}' "$TEMP/out" || fail 'range discovery order/bounds'
    run 0 a graalvm-community-17..17; contains '17-22.3.1+java17-graalvm-community'
    run 0 available 8..8; contains '8-1.8.0_99-b09-old-vendor'
    run 0 available other-vendor-25+; contains '26+1-other-vendor'
    run 1 available 27+; diagnostic 'No JDK found matching'
    before=$(< "$TEST_LOG")
    for command in available list install home env default exec uninstall; do
        for selector in 0+ 01+ 21++ 21.. 21..025 25..21 temurin-25..21 '$(exit 99)+'; do
            if [ "$command" = exec ]; then run 2 "$command" "$selector" -- java; else run 2 "$command" "$selector"; fi
        done
    done
    run 2 uninstall 21+
    run 2 uninstall temurin-21..25
    [ "$(< "$TEST_LOG")" = "$before" ] || fail 'invalid ranges accessed network'
    check 'range syntax, inclusive discovery order, Java-major metadata and uninstall exclusion'

    run 0 install 21..25; diagnostic 'Successfully installed 25+10-temurin'
    base=$XDG_DATA_HOME/jvm/jdks
    [ -d "$base/25+10-temurin" ] || fail 'remote range tie selection'
    # Reverse the remote tie order: no row-order preference is permitted.
    index; row 25+10 temurin; row 25+9 temurin; row 26+1 other-vendor
    run 0 install 21+; diagnostic 'Already installed 25+10-temurin'
    run 0 install 25+9-temurin
    run 0 install other-vendor-25+; diagnostic 'Successfully installed 26+1-other-vendor'
    index; row 21+1 other-vendor
    run 1 install 21..24; diagnostic 'No JDK found matching'
    index; row 27+1 temurin; row 27+1 temurin
    before=$(count_downloads)
    run 1 install 27+; diagnostic 'multiple artifact rows remain'
    [ "$(count_downloads)" = "$before" ] || fail 'range artifact collision downloaded'
    index; row 28+1 temurin zip "$ROOT/tests/fixtures/archives/jdk.zip"; row 28+1 temurin
    run 0 install 28..28
    check 'remote ranges use highest major, default distro, C ID ties and unchanged artifact checks'

    # Limit local range to 25, despite higher installed majors.
    run 0 default -v 25 25+9-temurin
    before=$(< "$TEST_LOG")
    for command in home h env e; do
        run 0 "$command" 21..25; contains '/25+9-temurin'
    done
    run 0 x 21..25 -- "$BASH_BIN" -c 'printf "%s\n" "$JAVA_HOME"'
    contains '/25+9-temurin'
    run 0 d 21..25
    [ "$base/default" -ef "$base/25+9-temurin" ] || fail 'range global default'
    run 1 default -v 21 21..25; diagnostic 'expected 21'
    [ ! -L "$base/21" ] || fail 'mismatched range changed default'
    run 0 list 21..25; contains '25+9-temurin'; contains '25+10-temurin'
    [[ $(< "$TEMP/out") != *'26+1-other-vendor'* ]] || fail 'list exceeded upper bound'
    run 0 l temurin-25+; contains '28+1-temurin'
    for command in install i; do
        run 0 "$command" 21..25; diagnostic 'Already installed 25+9-temurin'
        run 0 "$command" other-vendor-25+; diagnostic 'Already installed 26+1-other-vendor'
    done
    printf 'java=21..25\ndistro=unavailable-vendor\n' > .jvmrc
    run 0 i; diagnostic 'Already installed 25+9-temurin'
    run 0 install -d; diagnostic 'Already installed 25+9-temurin'
    [ "$base/default" -ef "$base/25+9-temurin" ] || fail 'configured range install -d selection'
    rm .jvmrc
    [ "$(< "$TEST_LOG")" = "$before" ] || fail 'local ranges used network'
    rm "$base/25"
    run 0 home 21..25; contains '/25+10-temurin'
    run 0 install 21..25; diagnostic 'Already installed 25+10-temurin'
    rm "$base/25"
    run 1 home temurin-25; diagnostic 'Multiple JDKs match'
    for id in missing 26+1-other-vendor; do
        if [ "$id" = missing ]; then dangling_link "$base/$id" "$base/25"
        else ln -s "$base/$id" "$base/25" || fail 'cannot prepare major link'; fi
        run 0 home 21..25; contains '/25+10-temurin'
        rm "$base/25"
    done
    mkdir "$base/25"
    run 0 home 21..25; contains '/25+10-temurin'
    rmdir "$base/25"
    # An eligible default of another distro must not override the filter.
    index; row 25+1 other-vendor; run 0 install 25+1-other-vendor
    run 0 default -v 25 25+1-other-vendor
    before=$(< "$TEST_LOG")
    run 0 home 21..25; contains '/25+1-other-vendor'
    run 0 home temurin-21..25; contains '/25+10-temurin'
    # A failed readlink is operational, not permission to fall back/install.
    cp "$TOOLS/readlink" "$TEMP/saved-readlink"
    printf '#!%s\nexit 1\n' "$BASH_BIN" > "$TOOLS/readlink"
    run 1 home 21..25; diagnostic 'cannot read range major default'
    run 1 install 21..25; diagnostic 'cannot read range major default'
    mv "$TEMP/saved-readlink" "$TOOLS/readlink"
    [ "$(< "$TEST_LOG")" = "$before" ] || fail 'range preference failure accessed network'
    # Existing range-shaped directories retain exact local-ID precedence.
    cp -R "$base/25+9-temurin" "$base/21+"
    run 0 home 21+; contains '/21+'
    run 0 list 21+; contains 'manifest invalid'
    run 0 uninstall 21+
    check 'offline range defaults, fallback, distro eligibility, exact IDs and operational failures'

    reset; index; row 21+1 other-vendor; row 25+1 temurin
    run 0 install other-vendor-21
    before=$(< "$TEST_LOG")
    run 0 home 21+; contains '/21+1-other-vendor'
    run 0 install 21+; diagnostic 'Already installed 21+1-other-vendor'
    [ "$(< "$TEST_LOG")" = "$before" ] || fail 'offline-first range checked for newer remote JDK'
    run 0 install temurin-21+; diagnostic 'Successfully installed 25+1-temurin'
    run 0 home temurin-21+; contains '/25+1-temurin'
    run 1 env 26+; diagnostic 'No JDK found matching'
    check 'range install-on-demand stays offline-first and continues with the installed ID'
    reset
}

configuration_checks() {
    local cmd before saved_config=$XDG_CONFIG_HOME args
    mkdir -p "$XDG_CONFIG_HOME/jvm"
    reset; index; row 21+1 temurin; row 25+1 temurin; row 22+1 vendor
    run 0 install
    diagnostic 'Successfully installed 25+1-temurin'
    run 0 i -d; diagnostic 'Already installed 25+1-temurin'
    run 0 default; contains '25+1-temurin'
    # Neither selectorless install form inherits the installed default.
    run 0 install vendor-22
    run 0 default vendor-22
    run 0 install; diagnostic 'Already installed 25+1-temurin'
    run 0 install -d; run 0 default; contains '25+1-temurin'
    printf 'java=22\ndistro=vendor\n' > "$XDG_CONFIG_HOME/jvm/config"
    run 0 install; diagnostic 'Already installed 22+1-vendor'
    printf ' # comment\n\n java = 21 \n' > .jvmrc
    # Java and distro inherit independently, even for explicit bare selectors.
    index; row 21+1 vendor; row 22+1 vendor; row 25+1 temurin
    run 0 install; diagnostic 'Successfully installed 21+1-vendor'
    printf 'distro=temurin\n' > .jvmrc
    index; row 22+1 temurin; row 21+1 vendor; row 22+1 vendor
    run 0 install; diagnostic 'Successfully installed 22+1-temurin'
    printf 'java=21+1-vendor\ndistro=temurin\n' > .jvmrc
    run 0 i; diagnostic 'Already installed 21+1-vendor'
    printf 'java=vendor-21\ndistro=temurin\n' > .jvmrc
    run 0 install; diagnostic 'Already installed 21+1-vendor'
    run 0 install vendor-22; diagnostic 'Already installed 22+1-vendor'
    printf 'java=21..25\ndistro=vendor\n' > .jvmrc
    index; row 24+1 vendor; row 25+1 temurin
    run 0 install; diagnostic 'Already installed 25+1-temurin'
    printf 'java=temurin-25+\ndistro=vendor\n' > .jvmrc
    run 0 install; diagnostic 'Already installed 25+1-temurin'
    check 'configuration Java/distro precedence, explicit IDs/distros/ranges and selectorless install'

    printf 'java=vendor-22\n' > .jvmrc
    before=$(cat "$TEST_LOG")
    for cmd in home h env e; do
        run 0 "$cmd"; contains '/22+1-vendor'
        run 0 "$cmd" 21+1-vendor; contains '/21+1-vendor'
    done
    for cmd in exec x; do
        run 0 "$cmd" _ "$BASH_BIN" -c 'printf "%s\n" "$JAVA_HOME"'
        contains '/22+1-vendor'
    done
    [ "$(cat "$TEST_LOG")" = "$before" ] || fail 'local configured resolution fetched metadata'
    printf 'java=vendor-99\n' > .jvmrc
    for cmd in home env; do
        run 1 "$cmd"; diagnostic 'No JDK found matching'
    done
    run 1 exec _ cat; diagnostic 'No JDK found matching'
    # A project miss cannot use global java or the global installed default.
    rm .jvmrc
    printf 'java=vendor-22\n' > "$XDG_CONFIG_HOME/jvm/config"
    run 0 home; contains '/22+1-vendor'
    for cmd in exec x; do
        run 0 "$cmd" _ -- "$BASH_BIN" -c 'printf "%s\n" "$JAVA_HOME"'
        contains '/22+1-vendor'
    done
    rm "$XDG_CONFIG_HOME/jvm/config"
    run 0 default vendor-22
    before=$(cat "$TEST_LOG")
    for cmd in home h env e; do
        run 0 "$cmd"; contains '/default'
    done
    for cmd in exec x; do
        run 0 "$cmd" _ "$BASH_BIN" -c 'printf "%s\n" "$JAVA_HOME"'
        contains '/22+1-vendor'
        [[ $(< "$TEMP/out") != */default* ]] || fail 'exec used mutable default'
    done
    rm "$XDG_DATA_HOME/jvm/jdks/default"
    dangling_link "$XDG_DATA_HOME/jvm/jdks/missing" "$XDG_DATA_HOME/jvm/jdks/default"
    for cmd in home env; do
        run 1 "$cmd"; diagnostic 'default JDK is missing or unusable'
    done
    run 1 exec _ cat; diagnostic 'default JDK is missing or unusable'
    rm "$XDG_DATA_HOME/jvm/jdks/default"
    printf 'unmanaged\n' > "$XDG_DATA_HOME/jvm/jdks/default"
    run 1 home; diagnostic 'default JDK is missing or unusable'
    [ "$(cat "$TEST_LOG")" = "$before" ] || fail 'default lookup fetched metadata'
    check 'configured home/env/exec aliases, configured misses and installed/broken default precedence'

    reset; index; row 25+1 temurin
    for cmd in home h env e exec x; do
        reset
        case "$cmd" in
            exec|x) run 0 "$cmd" _ "$BASH_BIN" -c 'printf "%s\n" "$JAVA_HOME"' ;;
            *) run 0 "$cmd" ;;
        esac
        diagnostic 'Successfully installed 25+1-temurin'
    done
    reset; index; row 25+1 vendor
    printf 'distro=vendor\n' > .jvmrc
    run 0 home; diagnostic 'Successfully installed 25+1-vendor'
    # Local selection remains across distributions; distro is only for install.
    index; row 21+1 vendor; row 21+2 vendor; row 21+1 temurin
    run 0 install 21+1-vendor
    printf 'java=21\ndistro=temurin\n' > .jvmrc
    before=$(cat "$TEST_LOG")
    run 0 home; contains '/21'
    run 0 install 21+2-vendor
    rm "$XDG_DATA_HOME/jvm/jdks/21"
    before=$(cat "$TEST_LOG")
    run 1 home; diagnostic 'Multiple JDKs match'
    dangling_link "$XDG_DATA_HOME/jvm/jdks/missing" "$XDG_DATA_HOME/jvm/jdks/21"
    run 1 home
    [ "$(cat "$TEST_LOG")" = "$before" ] || fail 'ambiguity/broken major triggered install'
    rm "$XDG_DATA_HOME/jvm/jdks/21"
    printf 'java=temurin-22\ndistro=vendor\n' > .jvmrc
    index; row 22+1 temurin
    run 0 e; diagnostic 'Successfully installed 22+1-temurin'
    check 'selectorless fallback installation, local distro independence and failures'

    for args in 'java=' 'java=_' 'java=0' 'java=21 # inline' 'java="21"' 'java=$HOME' 'java=$(touch sentinel)' 'java=`touch sentinel`' 'distro=bad/name' 'unknown=21' 'java=21\njava=22' 'distro=vendor\ndistro=temurin' 'invalid'; do
        printf '%b\n' "$args" > .jvmrc
        run 1 home; [ -s "$TEMP/err" ] || fail 'missing configuration diagnostic'
        run 1 exec _ "$BASH_BIN" -c 'exit 99'
        [ -s "$TEMP/err" ] || fail 'missing exec configuration diagnostic'
    done
    [ ! -e sentinel ] || fail 'executed configuration data'
    printf 'bad=config\n' > .jvmrc
    printf 'unknown=global\n' > "$XDG_CONFIG_HOME/jvm/config"
    # Explicit local selection and unaffected commands never consult configuration.
    for cmd in home env; do run 0 "$cmd" 22+1-temurin; done
    run 0 exec 22+1-temurin "$BASH_BIN" -c 'printf "%s\n" "$JAVA_HOME"'
    contains '/22+1-temurin'
    run 0 exec --help
    run 0 --help; run 0 --version
    run 0 available; run 0 list
    run 0 d; run 0 default -v 21
    run 2 install invalid; diagnostic 'selector must'
    run 2 uninstall; diagnostic 'usage:'
    index; row 23+1 temurin; row 23+1 vendor
    run 0 d -v 23 23; diagnostic 'Successfully installed 23+1-temurin'
    run 0 default 22+1-temurin
    run 0 d -v 22 22+1-temurin
    # Conflicting valid configuration must also leave default's Temurin
    # installation policy and selectorless queries untouched.
    printf 'java=21+1-vendor\ndistro=vendor\n' > .jvmrc
    printf 'java=25\ndistro=vendor\n' > "$XDG_CONFIG_HOME/jvm/config"
    index; row 26+1 temurin; row 26+1 vendor
    run 0 default 26; diagnostic 'Successfully installed 26+1-temurin'
    run 0 d; contains '26+1-temurin'
    # Malformed lower priority config is skipped if project supplies the key.
    printf 'bad=config\n' > "$XDG_CONFIG_HOME/jvm/config"
    printf 'java=22+1-temurin\ndistro=vendor\n' > .jvmrc
    run 0 home
    index; row 23+1 vendor
    run 0 install 23; diagnostic 'Successfully installed 23+1-vendor'
    rm .jvmrc
    run 1 home
    rm "$XDG_CONFIG_HOME/jvm/config"
    mkdir .jvmrc
    run 1 home; diagnostic 'cannot read configuration'
    rmdir .jvmrc
    dangling_link "$TEMP/absent-config" .jvmrc
    run 1 home; diagnostic 'cannot read configuration'
    rm .jvmrc
    mkdir "$XDG_CONFIG_HOME/jvm/config"
    run 1 home; diagnostic 'cannot read configuration'
    rmdir "$XDG_CONFIG_HOME/jvm/config"
    check 'literal parser errors, unreadable paths, lazy reads and default behavior unchanged'

    mkdir -p "$HOME/.config/jvm" child
    printf 'java=22+1-temurin' > "$HOME/.config/jvm/config"
    XDG_CONFIG_HOME=relative
    run 0 home; contains '/22+1-temurin'
    XDG_CONFIG_HOME=
    run 0 home; contains '/22+1-temurin'
    XDG_CONFIG_HOME=$saved_config
    # A drive-style absolute override uses the same conversion as other roots.
    # The harness cygpath stub returns its argument, so use a native converter
    # just for resolving this isolated configuration path.
    if [ -x '/usr/bin/cygpath' ]; then
        mv "$TOOLS/cygpath" "$TEMP/config-cygpath"
        printf '#!%s\nexec /usr/bin/cygpath "$@"\n' "$BASH_BIN" > "$TOOLS/cygpath"
        PATH=$ORIGINAL_PATH chmod +x "$TOOLS/cygpath"
        printf 'java=22+1-temurin\n' > "$saved_config/jvm/config"
        XDG_CONFIG_HOME=$(/usr/bin/cygpath -m "$saved_config")
        run 0 home; contains '/22+1-temurin'
        XDG_CONFIG_HOME=$saved_config
        rm "$saved_config/jvm/config" "$TOOLS/cygpath"
        mv "$TEMP/config-cygpath" "$TOOLS/cygpath"
    fi
    printf 'java=21+1-vendor\n' > .jvmrc
    cd child || exit 1
    run 0 home; contains '/default'
    cd .. || exit 1
    rm .jvmrc "$HOME/.config/jvm/config"
    rmdir child "$XDG_CONFIG_HOME/jvm" "$XDG_CONFIG_HOME"
    reset
    check 'absolute XDG fallback, unterminated lines, spaces and current-directory-only lookup'
}

if [ "${1:-}" = --config ]; then configuration_checks; exit 0; fi
if [ "${1:-}" = --ea ]; then ea_checks; exit 0; fi
if [ "${1:-}" = --types ]; then type_checks; exit 0; fi
if [ "${1:-}" = --ranges ]; then range_checks; exit 0; fi

if [ "${1:-}" = --manifest ]; then manifest_checks; exit 0; fi
if [ "${1:-}" = --inventory ]; then inventory_checks; exit 0; fi
if [ "${1:-}" = --flags ]; then flag_alias_checks; exit 0; fi
if [ "${1:-}" = --execution ]; then execution_checks; exit 0; fi
if [ "${1:-}" = --defaults ]; then default_checks; exit 0; fi

if [ "${1:-}" != --publication ]; then
run 0 list
[ "$(< "$TEMP/out")" = "No JDKs are installed. Use 'install' to install one" ] || fail 'wrong empty inventory message'
[ ! -s "$TEMP/err" ] || fail 'empty listing wrote a diagnostic'
for selector in 21 temurin temurin-21 21+1-temurin; do
    run 0 list "$selector"
    [ "$(< "$TEMP/out")" = "No JDKs are installed. Use 'install' to install one" ] || fail 'selector suppressed empty inventory message'
    [ ! -s "$TEMP/err" ] || fail 'empty selected listing wrote a diagnostic'
done
[ ! -e "$XDG_DATA_HOME" ] || fail 'empty listing created data storage'
run 2 list ''; run 2 list ../21; run 2 list extra extra
check 'empty offline inventory succeeds without creating storage; command usage'
ea_checks
type_checks
range_checks
java_major_checks
manifest_checks
inventory_checks
uninstall_checks
default_checks

index; row 21.0.2+9 vendor; run 0 install vendor-21; diagnostic '21.0.2+9-vendor'
diagnostic 'Successfully installed 21.0.2+9-vendor'; diagnostic 'Installing 21.0.2+9-vendor...'
[ -f "$XDG_DATA_HOME/jvm/jdks/21.0.2+9-vendor/lib/internal" ] || fail 'internal JDK link lost'
[ -f "$XDG_DATA_HOME/jvm/jdks/21.0.2+9-vendor/bin/java" ] || fail 'ID directory is not the JDK home'
[ -f "$XDG_DATA_HOME/jvm/jdks/21.0.2+9-vendor/.home-marker" ] || fail 'normalization lost dotfiles'
[ ! -e "$XDG_DATA_HOME/jvm/jdks/21.0.2+9-vendor/payload" ] || fail 'payload wrapper published'
before=$(count_downloads)
run 0 list; contains '21.0.2+9-vendor'; contains 'openj9'
run 0 install 21.0.2+9-vendor; diagnostic 'Already installed 21.0.2+9-vendor'
run 0 install vendor-21
[ "$(count_downloads)" = "$before" ] || fail 'idempotent install redownloaded'
mv "$TOOLS/curl" "$TEMP/curl"; mv "$TOOLS/wget" "$TEMP/wget"
rm -rf -- "$XDG_CACHE_HOME/jvm"
run 0 list; contains '21.0.2+9-vendor'
awk -F '\t+' 'NR==1 && $3!="VERSION" {exit 1} NR==2 && ($1!="21.0.2+9-vendor" || $3!="21+99") {exit 1}' "$TEMP/out" || fail 'offline VERSION must show persisted java_version'
run 0 install 21.0.2+9-vendor
mv "$TEMP/curl" "$TOOLS/curl"; mv "$TEMP/wget" "$TOOLS/wget"
check 'verified installation, internal links, durable offline listing and idempotent reinstall'

index; row 21.0.2+9 vendor; row 21.0.2+10 vendor; row 21.0.10+1 vendor
row 21.0.2+9 vendor zip "$ROOT/tests/fixtures/archives/jdk.zip"
run 1 install vendor-21; diagnostic 'Multiple JDKs match, try again using one of the following IDs:'; diagnostic '21.0.2+9-vendor'; diagnostic '21.0.10+1-vendor'
awk -F '\t+' 'NR==2 && ($1!="ID" || $2!="DISTRIBUTION" || $3!="VERSION" || $4!="JVM") {exit 1}
    NR>2 && $3!="21+99" {exit 1}
    END {if (NR!=5) exit 1}' "$TEMP/err" || fail 'install ambiguity must show a listing with each ID once'
run 0 install 21.0.2+10-vendor; diagnostic '21.0.2+10-vendor'
index; row 1.8.0_99-b09 old-vendor; row 1.8.0_100-b02 old-vendor
run 1 install old-vendor-8; diagnostic 'Multiple JDKs match, try again using one of the following IDs:'
run 0 install 8-1.8.0_99-b09-old-vendor
index; row 17.0.20.b2 old-vendor; row 17.0.20.b10 old-vendor
run 1 install old-vendor-17; diagnostic 'Multiple JDKs match, try again using one of the following IDs:'
index; row 22.0.1+8-LTS vendor; row 22.0.1+9 vendor
run 1 install vendor-22; diagnostic 'Multiple JDKs match, try again using one of the following IDs:'
index; row 22.0.2+9 vendor; row 22.1.0.1-Final gluon-graalvm
row 22.3.3+java17 graalvm tar.gz "$TEST_ARCHIVE" 17
run 0 install vendor-22; diagnostic '22.0.2+9-vendor'
run 0 install graalvm-17; diagnostic '22.3.3+java17-graalvm'
run 0 install gluon-graalvm-22; diagnostic '22.1.0.1-Final-gluon-graalvm'
index; row 22.1.0.1-final lower-vendor
run 0 install lower-vendor-22; diagnostic '22.1.0.1-final-lower-vendor'
index; row 25.0.1+7 vendor; row 25.0.1+7 other-vendor
run 0 install vendor-25; diagnostic '25.0.1+7-vendor'
run 0 install 25.0.1+7-other-vendor
run 1 install vendor-999; diagnostic 'No JDK found matching:'
run 1 install 999+1-missing; diagnostic 'No JDK found matching:'
run 2 install vendor; diagnostic 'selector must'
index; row 26.0.1-weird vendor
run 0 install vendor-26; diagnostic '26.0.1-weird-vendor'
run 0 install 26.0.1-weird-vendor
check 'IDs without version ordering, legacy/vendor labels, exact IDs, hyphenated distros and ambiguity'

index; row 22.0.2+9 temurin; row 22.3.3+java17 graalvm tar.gz "$TEST_ARCHIVE" 17; row 22.1.0.1-Final gluon-graalvm
run 0 install 22; diagnostic '22.0.2+9-temurin'
diagnostic 'Installing 22.0.2+9-temurin...'
before=$(count_downloads)
run 0 install temurin-22; diagnostic '22.0.2+9-temurin'
[ "$(count_downloads)" = "$before" ] || fail 'bare major and temurin-major resolved differently'
run 0 install graalvm-17; diagnostic '22.3.3+java17-graalvm'
run 0 available 22; contains '22.0.2+9-temurin'
run 0 available 17; contains '17-22.3.3+java17-graalvm'
index; row 23.0.2+9 other-vendor
run 1 install 23; diagnostic 'No JDK found matching:'
run 0 install other-vendor-23; diagnostic '23.0.2+9-other-vendor'
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
run 1 install graalvm-17; diagnostic '22.3.3+java17-graalvm'
run 1 install gluon-graalvm-22; diagnostic 'No JDK found matching:'
[ "$(count_downloads)" = "$before" ] || fail 'ambiguous selector downloaded an arbitrary artifact'
run 0 install 17-22.3.3+java17-graalvm
run 0 install 17-22.1.0.1-Final-gluon-graalvm
run 0 install 21.0.11b1163.125-jetbrains
check 'all 235 captured upstream version forms filter without ranking; ambiguity never downloads an arbitrary ID'
if [ "${1:-}" = --selectors ]; then
    printf 'PASS: focused installation and selector checks (offline)\n'
    exit 0
fi

reset; index; row 21+1 vendor zip; row 21+1 vendor tar.gz
run 0 install vendor-21; diagnostic '21+1-vendor'
[[ $(< "$TEST_LOG") = *'https://artifacts.invalid/tar.gz'* ]] || fail 'Linux did not prefer tar.gz'
reset; index; row 21+1 vendor tar.gz; row 21+1 vendor tar.gz; row 21+1 vendor zip
run 1 install vendor-21; diagnostic 'multiple artifact rows'
reset; index; row 21+1 vendor msi
run 1 install vendor-21; diagnostic 'No JDK found matching:'
run 1 available 21
TEST_ARCHIVE=$ROOT/tests/fixtures/archives/jdk.zip
reset; index; row 21+1 vendor zip
run 0 install vendor-21; diagnostic '21+1-vendor'
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
printf 'ga\tlinux\tx86_64\tjdk\thotspot\tv\tvendor\t21+99\t21+1\ttar.gz\thttps://artifacts.invalid/tar.gz\tjdk\t%s\t%s\t[]\n' "${bytes//[[:space:]]/}" "$sha" >> "$TEST_FIXTURE"
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
rm "$XDG_DATA_HOME/jvm/jdks/default"
printf 'keep\n' > "$XDG_DATA_HOME/jvm/jdks/default"
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
[ "$(< "$XDG_DATA_HOME/jvm/jdks/default")" = keep ] || fail 'default changed'
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
for role in first second; do
    [ ! -s "$TEMP/$role.out" ] || fail 'concurrent installer wrote to stdout'
    [[ $(< "$TEMP/$role.err") = *'Successfully installed 22+1-vendor'* ]] || fail 'concurrent installer did not report success'
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
contains '23+1-vendor'; contains '(invalid JDK)'
check 'independent staging, race loser success, publication failure and preservation of prior installation/default'

flag_alias_checks
execution_checks
configuration_checks

saved_data=$XDG_DATA_HOME; XDG_DATA_HOME=relative
index; row 24+1 vendor; run 0 install vendor-24
[ -f "$HOME/.local/share/jvm/jdks/24+1-vendor/.jvm-manifest" ] || fail 'relative XDG fallback failed'
XDG_DATA_HOME=$saved_data
[ ! -e "$XDG_CONFIG_HOME" ] && [ ! -e "$XDG_STATE_HOME" ] || fail 'unrelated storage touched'
printf 'PASS: %s installation checks (offline; host layouts simulated)\n' "$passed"
