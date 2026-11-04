#!/usr/bin/env bash
# Deterministic Unix-contract tests; Windows runs simulate uname, not native Unix.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/jvm-tool-test.XXXXXXXX")
trap 'status=$?; if [ "$status" != 0 ]; then cat "$TEMP/err" >&2 2>/dev/null || :; fi; rm -rf -- "$TEMP"' EXIT
trap 'exit 1' HUP INT TERM
export HOME="$TEMP/home space 'quote' !"'$literal `data`'
export XDG_DATA_HOME="$TEMP/data space 'quote' !"'$literal `data`'
export XDG_CONFIG_HOME="$TEMP/config" SHELL=/bin/bash
unset JAVA_HOME ZDOTDIR
mkdir -p "$HOME" "$TEMP/fixtures" "$TEMP/bin"
cp "$ROOT/jvm" "$ROOT/jvm.ps1" "$ROOT/jvm.cmd" "$TEMP/fixtures/"
printf '0.2.0\n' > "$TEMP/fixtures/latest.txt"
REAL_HASH=$(command -v sha256sum)
(cd "$TEMP/fixtures"; "$REAL_HASH" -t jvm jvm.ps1 jvm.cmd > SHA256SUMS)
export FIXTURES="$TEMP/fixtures" LOG="$TEMP/requests"
export TEST_EVAL_MARKER="$TEMP/unexpected-command"
cat > "$TEMP/bin/data" <<'EOF'
#!/usr/bin/env bash
printf 'unexpected command execution\n' > "$TEST_EVAL_MARKER"
EOF
cat > "$TEMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -eu
out= url=
while [ "$#" -gt 0 ]; do
    case $1 in -o) out=$2; shift ;; https:*) url=$1 ;; esac
    shift
done
printf '%s\n' "$url" >> "$LOG"
[ "${DOWNLOAD_FAIL:-0}" = 0 ] || exit 22
cp "$FIXTURES/${url##*/}" "$out"
EOF
cat > "$TEMP/bin/wget" <<'EOF'
#!/usr/bin/env bash
set -eu
out= url=
while [ "$#" -gt 0 ]; do
    case $1 in -O) out=$2; shift ;; https:*) url=$1 ;; esac
    shift
done
printf '%s\n' "$url" >> "$LOG"
[ "${DOWNLOAD_FAIL:-0}" = 0 ] || exit 8
if [ "${WGET_REDIRECT:-}" = downgrade ]; then
    printf '  HTTP/1.1 302 Found\n  Location: http://insecure.example/payload\n' >&2
    exit 8
fi
if [ "${WGET_REDIRECT:-}" = secure ]; then
    case $url in
        *://github.com/*) printf '  HTTP/1.1 302 Found\n  Location: https://release.example/%s\n' "${url##*/}" >&2; exit 8 ;;
    esac
fi
printf '  HTTP/1.1 200 OK\n' >&2
cp "$FIXTURES/${url##*/}" "$out"
EOF
cat > "$TEMP/bin/uname" <<'EOF'
#!/usr/bin/env bash
printf 'Linux\n'
EOF
chmod +x "$TEMP/bin/"*
export PATH="$TEMP/bin:$PATH"
INSTALLER=$ROOT/web/install.sh
DEST=$HOME/.local/bin STATE=$XDG_DATA_HOME/jvm/tool-install
count=0
ok() { count=$((count+1)); printf 'ok %s - %s\n' "$count" "$*"; }
run() { bash "$INSTALLER" "$@" > "$TEMP/out" 2> "$TEMP/err"; }
fails() {
    local expected=$1 status=0; shift
    run "$@" || status=$?
    [ "$status" = "$expected" ] || { cat "$TEMP/err" >&2; echo "expected $expected, got $status" >&2; exit 1; }
}
run --help
fails 2 --path --no-path
fails 2 --version 01.2.3
fails 2 --version "$(printf '0.2.0\ninvalid')"
fails 2 --profile /tmp/x
[ ! -e "$LOG" ] && [ ! -e "$HOME/.local" ]
ok 'help and invalid options have no side effects'
run --non-interactive --no-path --no-java
cmp "$DEST/jvm" "$ROOT/jvm"
[ ! -e "$HOME/.bashrc" ] && [ ! -e "$XDG_DATA_HOME/jvm/jdks" ]
[ "$(wc -l < "$LOG" | tr -d ' ')" = 3 ]
ok 'latest pins payload, exact bytes, unattended defaults preserve JDK storage'
: > "$LOG"
touch -t 200001010000 "$DEST/jvm"
touch "$TEMP/mtime-sentinel"
run --version 0.2.0 --non-interactive --no-path --no-java
! grep latest.txt "$LOG"
[ "$DEST/jvm" -ot "$TEMP/mtime-sentinel" ]
ok 'pinned matching reinstall bypasses latest'
run --path --java --shell bash --non-interactive
[ -f "$HOME/.profile" ] && [ ! -e "$HOME/.bash_profile" ]
# Start a real fresh Bash. Generated setup must treat metacharacters as data.
bash --noprofile --norc -c '. "$HOME/.profile"; . "$HOME/.bashrc"; . "$HOME/.profile"; [ "$JAVA_HOME" = "$XDG_DATA_HOME/jvm/jdks/default" ]; case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) exit 1 ;; esac'
bash --noprofile --norc -c 'PATH=; . "$HOME/.profile"; case "$PATH" in *:) ;; *) exit 1 ;; esac; unset PATH; . "$HOME/.profile"; case "$PATH" in *:) exit 1 ;; esac'
before=$(find "$HOME" -name '*.jvm-backup.*' | wc -l)
run --path --java --shell bash --non-interactive
[ "$before" = "$(find "$HOME" -name '*.jvm-backup.*' | wc -l)" ]
ok 'Bash startup executes safely, deduplicates and repeat setup preserves backups'
printf '\n# user edit\n' >> "$DEST/jvm"
fails 1 --no-path --no-java --non-interactive
grep -q 'locally modified' "$TEMP/err"
cp "$ROOT/jvm" "$DEST/jvm"
ok 'modified owned file refused'
cp "$FIXTURES/SHA256SUMS" "$TEMP/good-sums"
printf '<html>error</html>\n' > "$FIXTURES/SHA256SUMS"
fails 1 --non-interactive
cp "$TEMP/good-sums" "$FIXTURES/SHA256SUMS"
printf bad >> "$FIXTURES/jvm"
fails 1 --non-interactive
cmp "$DEST/jvm" "$ROOT/jvm"
cp "$ROOT/jvm" "$FIXTURES/jvm"
DOWNLOAD_FAIL=1 fails 1 --non-interactive
printf '0.2.0\n0.3.0\n' > "$FIXTURES/latest.txt"
fails 1 --non-interactive
printf '0.2.0\ninvalid' > "$FIXTURES/latest.txt"
fails 1 --non-interactive
printf '0.2.0\n' > "$FIXTURES/latest.txt"
ok 'HTTP failures, malformed metadata and checksum mismatch preserve tool'
printf '# >>> jvm path >>>\n' >> "$HOME/.bashrc"
fails 1 --path --shell bash --non-interactive
grep -q 'Tool was installed' "$TEMP/err"
sed '$d' "$HOME/.bashrc" > "$TEMP/profile"; cp "$TEMP/profile" "$HOME/.bashrc"
ok 'corrupt markers fail setup after usable publication'
printf '# existing login\n' > "$HOME/.bash_login"
run --path --shell bash --no-java --non-interactive
grep -q '^# existing login' "$HOME/.bash_login"
[ ! -e "$HOME/.bash_profile" ]
ok 'Bash honors login precedence'
mkdir -p "$STATE/lock"
printf '%s\n' "$$" > "$STATE/lock/pid"
fails 1 --non-interactive --no-path --no-java
grep -q 'another installer' "$TEMP/err"
rm "$STATE/lock/pid"; rmdir "$STATE/lock"
ok 'live competing installer refused'
mkdir "$STATE/transaction"
cp "$STATE/record" "$STATE/transaction/old-record"
cp "$STATE/record" "$STATE/transaction/new-record"
cp -p "$DEST/jvm" "$STATE/transaction/old-jvm"
touch "$STATE/transaction/ready"
printf partial > "$DEST/jvm"
run --non-interactive --no-path --no-java
cmp "$DEST/jvm" "$ROOT/jvm"
[ ! -e "$STATE/transaction" ]
ok 'interrupted update restores prior payload and ownership before retry'
# Force failures after a replacement payload has been published, before record
# publication. Rollback must restore a prior usable version, not the new bytes.
REAL_MV=$(command -v mv)
export REAL_MV INJECT_TARGET="$STATE/record" INJECT_ONCE="$TEMP/injected"
cat > "$TEMP/bin/mv" <<'EOF'
#!/usr/bin/env bash
set -eu
last=
for arg in "$@"; do last=$arg; done
if [ -n "${INJECT_MODE:-}" ] && [ "$last" = "$INJECT_TARGET" ] && [ ! -e "$INJECT_ONCE" ]; then
    : > "$INJECT_ONCE"
    if [ "$INJECT_MODE" = signal ]; then kill -TERM "$PPID"; fi
    exit 1
fi
exec "$REAL_MV" "$@"
EOF
chmod +x "$TEMP/bin/mv"
printf '\n# new release fixture\n' >> "$FIXTURES/jvm"
(cd "$FIXTURES"; "$REAL_HASH" -t jvm jvm.ps1 jvm.cmd > SHA256SUMS)
for mode in fail signal; do
    rm -f "$INJECT_ONCE"
    INJECT_MODE=$mode fails 1 --version 0.2.1 --non-interactive --no-path --no-java
    cmp "$DEST/jvm" "$ROOT/jvm"
    [ "$(sed -n '2p' "$STATE/record")" = 0.2.0 ]
done
ok 'publication error and catchable interruption restore old payload/record'
run --version 0.2.1 --non-interactive --no-path --no-java
cmp "$DEST/jvm" "$FIXTURES/jvm"
[ "$(sed -n '2p' "$STATE/record")" = 0.2.1 ]
cp "$ROOT/jvm" "$FIXTURES/jvm"
(cd "$FIXTURES"; "$REAL_HASH" -t jvm jvm.ps1 jvm.cmd > SHA256SUMS)
run --version 0.2.0 --non-interactive --no-path --no-java
ok 'owned update and explicit version replacement'
# The first profile in a two-file step must be restored if the second fails.
cp "$HOME/.bashrc" "$TEMP/original-bashrc"
cp "$HOME/.bash_login" "$TEMP/original-login"
printf '# original login before failed publication\n' > "$HOME/.bash_login"
printf '# force path regeneration\n' > "$HOME/.bashrc"
cp "$HOME/.bashrc" "$TEMP/before-rollback"
rm -f "$INJECT_ONCE"
INJECT_TARGET="$HOME/.bash_login" INJECT_MODE=fail fails 1 --path --shell bash --no-java --non-interactive
cmp "$HOME/.bashrc" "$TEMP/before-rollback"
cp "$TEMP/original-bashrc" "$HOME/.bashrc"
cp "$TEMP/original-login" "$HOME/.bash_login"
ok 'multi-profile setup step rolls back earlier edits on failure'
mkdir "$STATE/transaction"
printf 'do not delete\n' > "$STATE/transaction/unknown"
fails 1 --non-interactive --no-path --no-java
grep -q 'do not delete' "$STATE/transaction/unknown"
rm "$STATE/transaction/unknown"; rmdir "$STATE/transaction"
ok 'unknown recovery material retained for inspection'
custom="$HOME/custom-profile"
printf '# preserved\n' > "$custom"
ln -s "$custom" "$HOME/link-profile"
if [ -L "$HOME/link-profile" ]; then
    fails 1 --path --shell zsh --profile "$HOME/link-profile" --non-interactive
else
    printf 'Native symlink assertion requires hosted Unix (ln made a copy here).\n'
fi
run --path --shell zsh --profile "$custom" --no-java --non-interactive
grep -q '^# preserved' "$custom"
ok 'custom profile preserves content and symlink profiles are refused'
# Force capability detection to exercise wget without contacting the network.
sed '/# BEGIN GENERATED WINDOWS INSTALLER/,$d' "$INSTALLER" > "$TEMP/wget-installer"
cat >> "$TEMP/wget-installer" <<'EOF'
command() { if [ "$1" = -v ] && [ "$2" = curl ]; then return 1; fi; builtin command "$@"; }
main "$@"
EOF
INSTALLER=$TEMP/wget-installer
run --no-path --no-java --non-interactive
ok 'wget-only capability path'
WGET_REDIRECT=secure run --no-path --no-java --non-interactive
WGET_REDIRECT=downgrade fails 1 --no-path --no-java --non-interactive
! grep '^http://' "$LOG"
ok 'wget follows verified HTTPS hops and rejects downgrade before any HTTP request'
INSTALLER=$ROOT/web/install.sh
# Capability alternatives are tested without installing utilities.
for hasher in shasum openssl; do
    if ! command -v "$hasher" >/dev/null 2>&1; then continue; fi
    sed '/# BEGIN GENERATED WINDOWS INSTALLER/,$d' "$INSTALLER" > "$TEMP/hash-installer"
    cat >> "$TEMP/hash-installer" <<'EOF'
command() {
    if [ "$1" = -v ]; then
        case $2 in sha256sum) return 1 ;; shasum) [ "$TEST_HASHER" != openssl ] || return 1 ;; esac
    fi
    builtin command "$@"
}
main "$@"
EOF
    INSTALLER=$TEMP/hash-installer
    TEST_HASHER=$hasher run --no-path --no-java --non-interactive
    INSTALLER=$ROOT/web/install.sh
done
ok 'available SHA-256 alternatives'
for shell in zsh fish csh tcsh; do
    profile="$HOME/$shell-profile"
    run --path --java --shell "$shell" --profile "$profile" --non-interactive
    [ "$(grep -c '^# >>> jvm ' "$profile")" = 2 ]
done
ok 'all supported shell formats generated'
ZDOTDIR="$HOME/custom-zdot" run --shell zsh --path --no-java --non-interactive
[ -f "$HOME/custom-zdot/.zshrc" ]
run --shell fish --path --java --non-interactive
[ -f "$XDG_CONFIG_HOME/fish/conf.d/jvm.fish" ]
ok 'exported ZDOTDIR and Fish XDG configuration root'
request_count=$(wc -l < "$LOG")
HOME=relative fails 1 --non-interactive --no-path --no-java
[ "$request_count" = "$(wc -l < "$LOG")" ]
mkdir -p "$TEMP/conflict-home/.local/bin"
printf unowned > "$TEMP/conflict-home/.local/bin/jvm"
HOME="$TEMP/conflict-home" XDG_DATA_HOME="$TEMP/conflict-data" fails 1 --non-interactive --no-path --no-java
[ "$(cat "$TEMP/conflict-home/.local/bin/jvm")" = unowned ]
ok 'relative HOME rejected before networking and unowned file preserved'
HOME="$TEMP/fallback-home" XDG_DATA_HOME=relative run --non-interactive --no-path --no-java
[ -f "$TEMP/fallback-home/.local/share/jvm/tool-install/record" ]
ok 'relative XDG override falls back beneath isolated HOME'
# Never depend on a contributor's controlling terminal in the offline suite.
cat "$INSTALLER" | HOME="$TEMP/piped-home" XDG_DATA_HOME="$TEMP/piped-data" bash -s -- --version 0.2.0 --non-interactive > "$TEMP/out" 2> "$TEMP/err"
[ -f "$TEMP/piped-home/.local/bin/jvm" ] && [ ! -e "$TEMP/piped-home/.bashrc" ]
ok 'piped bootstrap skips unspecified setup without consuming script stdin'
if [ "${1:-}" = --native-shells ]; then
    # Hosted Unix only: use actual shells, including paths with apostrophes/spaces.
    native_shells='zsh fish csh tcsh'
    if [ -n "${2:-}" ]; then
        case $2 in zsh|fish|csh|tcsh) native_shells=$2 ;; *) echo 'Unsupported native test shell' >&2; exit 2 ;; esac
    fi
    native_failures=0
    for shell in $native_shells; do
        command -v "$shell" >/dev/null
        profile="$HOME/$shell-profile"
        printf 'Checking native %s explicit sourcing\n' "$shell"
        native_status=0
        if [ "$shell" = fish ]; then
            "$shell" --no-config -c 'source "$argv[1]"; source "$argv[1]"; test "$JAVA_HOME" = "$XDG_DATA_HOME/jvm/jdks/default"' "$profile" || native_status=$?
        elif [ "$shell" = zsh ]; then
            "$shell" -f -c '. "$1"; . "$1"; [ "$JAVA_HOME" = "$XDG_DATA_HOME/jvm/jdks/default" ]' test "$profile" || native_status=$?
        else
            # Preserve literal words through C-shell substitution phases. The
            # script path itself is simple; the sourced fixture path is not.
            cat > "$TEMP/check-native.csh" <<'EOF'
unset path
source $argv[1]:q
source $argv[1]:q
set test_home = "$JAVA_HOME"
set test_expected = "$XDG_DATA_HOME/jvm/jdks/default"
if ( $test_home:q != $test_expected:q ) exit 1
EOF
            "$shell" -f "$TEMP/check-native.csh" "$profile" || native_status=$?
        fi
        [ ! -e "$TEST_EVAL_MARKER" ] || native_status=1
        if [ "$native_status" != 0 ]; then
            printf 'FAIL: native %s sourcing (status %s); generated profile follows\n' "$shell" "$native_status" >&2
            cat "$profile" >&2
            native_failures=$((native_failures+1))
        fi
    done
    if [ "$native_failures" = 0 ]; then ok 'actual native shells source managed setup twice'; fi
    # Also launch normal startup paths, not just explicit source commands.
    run --shell zsh --path --java --non-interactive
    run --shell csh --path --java --non-interactive
    printf '# tcsh startup\n' > "$HOME/.tcshrc"
    run --shell tcsh --path --java --non-interactive
    bash --noprofile --rcfile "$HOME/.bashrc" -i -c '[ "$JAVA_HOME" = "$XDG_DATA_HOME/jvm/jdks/default" ]' > "$TEMP/startup-out" 2> "$TEMP/startup-err"
    [ ! -s "$TEMP/startup-out" ]
    for shell in $native_shells; do
        printf 'Checking native %s startup\n' "$shell"
        native_status=0
        case $shell in
            zsh) zsh -d -i -c '[ "$JAVA_HOME" = "$XDG_DATA_HOME/jvm/jdks/default" ]' > "$TEMP/startup-out" ;;
            fish) fish --private -c 'test "$JAVA_HOME" = "$XDG_DATA_HOME/jvm/jdks/default"' > "$TEMP/startup-out" ;;
            csh|tcsh) "$shell" -c 'set test_home = "$JAVA_HOME"; set test_expected = "$XDG_DATA_HOME/jvm/jdks/default"; if ( $test_home:q != $test_expected:q ) exit 1' > "$TEMP/startup-out" ;;
        esac || native_status=$?
        [ ! -s "$TEMP/startup-out" ] && [ ! -e "$TEST_EVAL_MARKER" ] || native_status=1
        if [ "$native_status" != 0 ]; then
            printf 'FAIL: native %s startup (status %s)\n' "$shell" "$native_status" >&2
            cat "$TEMP/startup-out" >&2
            native_failures=$((native_failures+1))
        fi
    done
    [ "$native_failures" = 0 ] || { printf '%s native shell checks failed\n' "$native_failures" >&2; exit 1; }
    ok 'fresh shells load native startup files silently'
fi
printf '%s installer checks passed\n' "$count"
