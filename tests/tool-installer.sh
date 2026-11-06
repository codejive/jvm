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
pack_fixture() {
    (cd "$TEMP/fixtures"; tar -czf jvm.tar.gz jvm jvm.ps1 jvm.cmd latest.txt)
    "$REAL_HASH" < "$TEMP/fixtures/jvm.tar.gz" | awk '{print $1}' > "$TEMP/fixtures/jvm.tar.gz.sha256"
}
pack_fixture
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
cp "$FIXTURES/${url##*/}" "$out"
EOF
cat > "$TEMP/bin/uname" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${TEST_HOST:-Linux}"
EOF
chmod +x "$TEMP/bin/"*
export PATH="$TEMP/bin:$PATH"
INSTALLER=$ROOT/web/install.sh
DEST=$HOME/.local/bin
# Load functions only, retaining the real input parser without invoking installation.
sed '$d' "$INSTALLER" > "$TEMP/functions.sh"
(
    . "$TEMP/functions.sh"
    for answer in '' y Y yes Yes YES; do setup_answer_yes "$answer"; done
    for answer in n N no NO invalid ' '; do ! setup_answer_yes "$answer"; done
    NONINTERACTIVE=1
    ! consent ask 'must not prompt'
    consent yes 'explicit consent'
    ! consent no 'explicit refusal'
)
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
fails 2 --local --user
fails 2 --local --local
fails 2 --version 01.2.3
fails 2 --version "$(printf '0.2.0\ninvalid')"
fails 2 --profile /tmp/x
[ ! -e "$LOG" ] && [ ! -e "$HOME/.local" ]
ok 'help and invalid options have no side effects'
# Exercise the first question with fixture input instead of a controlling terminal.
sed -e 's|> /dev/tty|>\&2|g' -e 's|< /dev/tty|< "$TEST_INSTALLER_ANSWERS"|g' -e 's|} 2>/dev/null|}|g' "$INSTALLER" > "$TEMP/prompt-installer"
export TEST_INSTALLER_ANSWERS="$TEMP/answers"
mkdir -p "$TEMP/project with spaces"
printf '1\n' > "$TEMP/answers"
(
    cd "$TEMP/project with spaces"
    bash "$TEMP/prompt-installer" --path --java > "$TEMP/out" 2> "$TEMP/err"
)
for name in jvm jvm.ps1 jvm.cmd; do cmp "$TEMP/project with spaces/$name" "$ROOT/$name"; done
grep -q 'How would you like to install jvm?' "$TEMP/err"
grep -q '^  ./jvm install$' "$TEMP/err"
! grep -q 'Enable this?\|future terminals\|Open a new terminal' "$TEMP/err"
[ ! -e "$HOME/.local" ] && [ ! -e "$HOME/.bashrc" ] && [ ! -e "$XDG_DATA_HOME" ]
# Reinstall explicitly without prompting, and preserve copies after failed verification.
(
    cd "$TEMP/project with spaces"
    run --local --non-interactive
    DOWNLOAD_FAIL=1 fails 1 --local --non-interactive
)
for name in jvm jvm.ps1 jvm.cmd; do cmp "$TEMP/project with spaces/$name" "$ROOT/$name"; done
ok 'first-question local choice and explicit local reinstall copy three scripts without setup'
: > "$LOG"
run --non-interactive --no-path --no-java
cmp "$DEST/jvm" "$ROOT/jvm"
[ ! -e "$HOME/.bashrc" ] && [ ! -e "$XDG_DATA_HOME/jvm/jdks" ]
[ "$(wc -l < "$LOG" | tr -d ' ')" = 3 ]
ok 'latest pins payload, exact bytes, unattended defaults preserve JDK storage'
grep -q 'No JDK is installed yet' "$TEMP/err"
grep -q '^  jvm install$' "$TEMP/err"
! grep -q 'Open a new terminal' "$TEMP/err"
mkdir -p "$XDG_DATA_HOME/jvm/jdks/default/bin" "$XDG_DATA_HOME/jvm/jdks/21/bin" "$XDG_DATA_HOME/jvm/jdks/broken/bin"
for id in default 21; do
    for name in java javac; do printf '#!/bin/sh\nexit 99\n' > "$XDG_DATA_HOME/jvm/jdks/$id/bin/$name"; chmod +x "$XDG_DATA_HOME/jvm/jdks/$id/bin/$name"; done
done
run --non-interactive --no-path --no-java
grep -q 'No JDK is installed yet' "$TEMP/err"
mkdir -p "$XDG_DATA_HOME/jvm/jdks/.custom JDK/bin"
for name in java javac; do cp "$XDG_DATA_HOME/jvm/jdks/default/bin/$name" "$XDG_DATA_HOME/jvm/jdks/.custom JDK/bin/$name"; done
run --non-interactive --no-path --no-java
! grep -q 'No JDK is installed yet' "$TEMP/err"
grep -q '^  jvm list$' "$TEMP/err"
(
    cd "$TEMP/project with spaces"
    run --local --non-interactive
    grep -q '^  ./jvm list$' "$TEMP/err"
    ! grep -q 'No JDK is installed yet' "$TEMP/err"
)
# Leave reserved and broken directories in place; exclude a linked installation.
mv "$XDG_DATA_HOME/jvm/jdks/.custom JDK" "$TEMP/external-jdk"
ln -s "$TEMP/external-jdk" "$XDG_DATA_HOME/jvm/jdks/linked"
# Git Bash may copy instead of making a symlink when symlinks are disabled.
if [ -L "$XDG_DATA_HOME/jvm/jdks/linked" ]; then
    run --non-interactive --no-path --no-java
    grep -q 'No JDK is installed yet' "$TEMP/err"
fi
mv "$XDG_DATA_HOME/jvm/jdks/linked" "$TEMP/linked-fixture"
ok 'post-setup advice checks usable managed JDKs without executing launchers'

: > "$LOG"
run --version 0.2.0 --non-interactive --no-path --no-java
! grep latest.txt "$LOG"
ok 'pinned install bypasses latest'
run --path --java --shell bash --non-interactive
[ "$(grep -c 'optional settings below' "$TEMP/err")" = 1 ]
[ "$(grep -c 'No:  leave your environment settings unchanged.' "$TEMP/err")" = 2 ]
grep -q 'Run jvm from any directory?' "$TEMP/err"
grep -q "Use jvm's default JDK for Java commands?" "$TEMP/err"
grep -q 'Open a new terminal application' "$TEMP/err"
[ -f "$HOME/.profile" ] && [ ! -e "$HOME/.bash_profile" ]
# Start a real fresh Bash. Generated setup must treat metacharacters as data.
bash --noprofile --norc -c '. "$HOME/.profile"; . "$HOME/.bashrc"; . "$HOME/.profile"; [ "$JAVA_HOME" = "$XDG_DATA_HOME/jvm/jdks/default" ]; case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) exit 1 ;; esac'
bash --noprofile --norc -c 'PATH=; . "$HOME/.profile"; case "$PATH" in *:) ;; *) exit 1 ;; esac; unset PATH; . "$HOME/.profile"; case "$PATH" in *:) exit 1 ;; esac'
cp "$HOME/.bashrc" "$TEMP/before-repeat"
run --path --java --shell bash --non-interactive
cmp "$HOME/.bashrc" "$TEMP/before-repeat"
! grep -q "Let's set up jvm" "$TEMP/err"
! grep -q "Open a new terminal" "$TEMP/err"
ok 'Bash startup executes safely, deduplicates and repeat setup preserves profiles'
cp "$FIXTURES/jvm.tar.gz.sha256" "$TEMP/good-sums"
printf '<html>error</html>\n' > "$FIXTURES/jvm.tar.gz.sha256"
fails 1 --non-interactive
cp "$TEMP/good-sums" "$FIXTURES/jvm.tar.gz.sha256"
printf bad >> "$FIXTURES/jvm.tar.gz"
fails 1 --non-interactive
cmp "$DEST/jvm" "$ROOT/jvm"
pack_fixture
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
ok 'corrupt markers fail setup after tool copy'
printf '# existing login\n' > "$HOME/.bash_login"
run --path --shell bash --no-java --non-interactive
grep -q '^# existing login' "$HOME/.bash_login"
[ ! -e "$HOME/.bash_profile" ]
ok 'Bash honors login precedence'
REAL_MV=$(command -v mv)
export REAL_MV INJECT_TARGET="$HOME/.bash_login" INJECT_ONCE="$TEMP/injected"
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
sed '/^main "\$@"$/d' "$INSTALLER" > "$TEMP/wget-installer"
cat >> "$TEMP/wget-installer" <<'EOF'
command() { if [ "$1" = -v ] && [ "$2" = curl ]; then return 1; fi; builtin command "$@"; }
main "$@"
EOF
INSTALLER=$TEMP/wget-installer
run --no-path --no-java --non-interactive
ok 'wget-only capability path'
INSTALLER=$ROOT/web/install.sh
# Capability alternatives are tested without installing utilities.
for hasher in shasum openssl; do
    if ! command -v "$hasher" >/dev/null 2>&1; then continue; fi
    sed '/^main "\$@"$/d' "$INSTALLER" > "$TEMP/hash-installer"
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
ok 'relative HOME rejected before networking'
HOME="$TEMP/fallback-home" XDG_DATA_HOME=relative run --path --java --shell bash --non-interactive
grep -F '.local/share/jvm/jdks/default' "$TEMP/fallback-home/.bashrc" >/dev/null
ok 'relative XDG override uses fallback for Java setup'
# Never depend on a contributor's controlling terminal in the offline suite.
cat "$INSTALLER" | HOME="$TEMP/piped-home" XDG_DATA_HOME="$TEMP/piped-data" bash -s -- --version 0.2.0 --non-interactive > "$TEMP/out" 2> "$TEMP/err"
[ -f "$TEMP/piped-home/.local/bin/jvm" ] && [ ! -e "$TEMP/piped-home/.bashrc" ]
ok 'piped bootstrap skips unspecified setup without consuming script stdin'
if [ "${1:-}" = --native-shells ]; then
    # Hosted Unix only: use actual shells, including paths with apostrophes/spaces.
    # BSD csh expands its inherited HOME before even parsing -f (csh.c/set.c).
    # Keep its bootstrap HOME safe; sourced tool/data paths remain hostile.
    csh_bootstrap_home=$TEMP/csh-bootstrap-home
    mkdir "$csh_bootstrap_home"
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
if ( $#path != 2 ) exit 1
set test_java_bin = "$XDG_DATA_HOME/jvm/jdks/default/bin"
if ( $path[1]:q != $test_java_bin:q ) exit 1
if ( $path[2]:q != $argv[2]:q ) exit 1
EOF
            if [ "$shell" = csh ]; then
                HOME="$csh_bootstrap_home" "$shell" -f "$TEMP/check-native.csh" "$profile" "$DEST" || native_status=$?
            else
                "$shell" -f "$TEMP/check-native.csh" "$profile" "$DEST" || native_status=$?
            fi
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
    cp "$HOME/.cshrc" "$csh_bootstrap_home/.cshrc"
    bash --noprofile --rcfile "$HOME/.bashrc" -i -c '[ "$JAVA_HOME" = "$XDG_DATA_HOME/jvm/jdks/default" ]' > "$TEMP/startup-out" 2> "$TEMP/startup-err"
    [ ! -s "$TEMP/startup-out" ]
    for shell in $native_shells; do
        printf 'Checking native %s startup\n' "$shell"
        native_status=0
        case $shell in
            zsh) zsh -d -i -c '[ "$JAVA_HOME" = "$XDG_DATA_HOME/jvm/jdks/default" ]' > "$TEMP/startup-out" ;;
            fish) fish --private -c 'test "$JAVA_HOME" = "$XDG_DATA_HOME/jvm/jdks/default"' > "$TEMP/startup-out" ;;
            csh) HOME="$csh_bootstrap_home" "$shell" -c 'set test_home = "$JAVA_HOME"; set test_expected = "$XDG_DATA_HOME/jvm/jdks/default"; if ( $test_home:q != $test_expected:q ) exit 1' > "$TEMP/startup-out" ;;
            tcsh) "$shell" -c 'set test_home = "$JAVA_HOME"; set test_expected = "$XDG_DATA_HOME/jvm/jdks/default"; if ( $test_home:q != $test_expected:q ) exit 1' > "$TEMP/startup-out" ;;
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
# Exercise Windows file copying with offline transfers and isolated roots.
cat > "$TEMP/bin/cygpath" <<'EOF'
#!/usr/bin/env bash
printf 'C:/fixture/default\n'
EOF
chmod +x "$TEMP/bin/cygpath"
for host in MINGW64_NT MSYS_NT CYGWIN_NT; do
    winhome=$TEMP/$host-home windata=$TEMP/$host-data
    HOME="$winhome" XDG_DATA_HOME="$windata" TEST_HOST=$host run --path --java --shell bash --non-interactive
    for name in jvm jvm.ps1 jvm.cmd; do cmp "$winhome/.local/bin/$name" "$ROOT/$name"; done
    HOME="$winhome" XDG_DATA_HOME="$windata" TEST_HOST=$host run --no-path --no-java --non-interactive
    printf '\n# updated Windows fixture\n' >> "$FIXTURES/jvm.ps1"
    pack_fixture
    HOME="$winhome" XDG_DATA_HOME="$windata" TEST_HOST=$host run --version 0.2.1 --no-path --no-java --non-interactive
    for name in jvm jvm.ps1 jvm.cmd; do cmp "$winhome/.local/bin/$name" "$FIXTURES/$name"; done
    cp "$ROOT/jvm.ps1" "$FIXTURES/jvm.ps1"
    pack_fixture
done
rm "$TEMP/bin/cygpath"
ok 'Windows three-file installation and update'
printf '%s installer checks passed\n' "$count"
