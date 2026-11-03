#!/usr/bin/env bash
# Optional real download/runtime check; never part of the offline suite.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BASH_BIN=${BASH:-bash}

[ "$#" -le 1 ] && { [ "$#" -eq 0 ] || [ -n "$1" ]; } || {
    printf '%s\n' 'Usage: bash tests/jdk-smoke.sh [selector]' >&2
    exit 2
}
case "${1:-}" in
    --help)
        printf '%s\n' 'Usage: bash tests/jdk-smoke.sh [selector]' \
            'Downloads, executes and removes a real JDK in temporary HOME/XDG storage.' \
            'Default selector: temurin-21. Requires network access and normal jvm utilities.'
        exit 0 ;;
esac
selector=${1:-temurin-21}
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/jvm-jdk-smoke.XXXXXXXX")
TEMP=$(cd "$TEMP" && pwd -P)
cleanup() {
    # Unlink surviving Windows junctions before recursively cleaning staging.
    local link
    for link in "$TEMP/data with spaces/jvm/jdks/"*; do
        [ ! -L "$link" ] || rm -- "$link"
    done
    rm -rf -- "$TEMP"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
step() { printf 'Checking %s\n' "$*"; }
jvm() { "$BASH_BIN" "$ROOT/jvm" "$@"; }

export HOME="$TEMP/home with spaces" XDG_DATA_HOME="$TEMP/data with spaces"
export XDG_CACHE_HOME="$TEMP/cache" XDG_CONFIG_HOME="$TEMP/config" XDG_STATE_HOME="$TEMP/state"
mkdir -p "$HOME" "$TEMP/project with spaces" "$TEMP/offline-bin"
cd "$TEMP/project with spaces"
# Avoid caller Java settings affecting compilation or runtime checks.
unset JAVA_HOME GRAALVM_HOME CLASSPATH JAVA_TOOL_OPTIONS JDK_JAVA_OPTIONS _JAVA_OPTIONS

step "download, checksum verification and installation of $selector"
jvm install "$selector"
id=$(jvm default)
[ -n "$id" ] || fail 'first install did not select a default'
home=$(jvm home "$id")
[ -f "$home/.jvm-manifest" ] || fail 'installed JDK has no durable manifest'
[ "$(jvm home)" -ef "$home" ] || fail 'global default does not reference the installed JDK'

# Remove metadata and make both transfer adapters fail visibly if called. The
# remaining checks must work from the installed manifest, even on reinstall.
rm -rf -- "$XDG_CACHE_HOME"
export JVM_SMOKE_REQUESTS="$TEMP/unexpected-requests"
for tool in curl wget; do
    printf '#!%s\n' "$BASH_BIN" > "$TEMP/offline-bin/$tool"
    cat >> "$TEMP/offline-bin/$tool" <<'EOF'
printf '%s\n' "$0 $*" >> "$JVM_SMOKE_REQUESTS"
printf '%s\n' 'unexpected network request during offline JDK smoke checks' >&2
exit 1
EOF
    chmod +x "$TEMP/offline-bin/$tool"
done
export PATH="$TEMP/offline-bin:$PATH"

step 'offline listing, selection and idempotent exact-ID reinstall'
jvm list > "$TEMP/list.out"
grep -F -e "$id" "$TEMP/list.out" >/dev/null || fail 'installed ID missing from list'
jvm install "$id"
[ "$(jvm default)" = "$id" ] || fail 'reinstall changed the default'
[ "$(jvm home "$id")" = "$home" ] || fail 'reinstall changed the physical home'

step 'real java/javac execution and compilation through jvm exec'
jvm exec _ java -version
jvm exec "$id" javac -version
cat > JvmSmoke.java <<'EOF'
import java.io.File;

public class JvmSmoke {
    public static void main(String[] args) throws Exception {
        File selected = new File(System.getenv("JAVA_HOME")).getCanonicalFile();
        File runtime = new File(System.getProperty("java.home")).getCanonicalFile();
        // Java 8 reports the nested JRE as java.home.
        if (!runtime.equals(selected) && !runtime.getParentFile().equals(selected)) {
            throw new AssertionError("Runtime is outside selected JAVA_HOME: " + runtime);
        }
        if (args.length != 1 || !"argument with spaces".equals(args[0])) {
            throw new AssertionError("Command arguments were not preserved");
        }
        System.out.println("jvm real JDK smoke passed");
    }
}
EOF
jvm exec "$id" javac JvmSmoke.java
[ -f JvmSmoke.class ] || fail 'javac did not produce a class file'
output=$(jvm exec _ java -cp . JvmSmoke 'argument with spaces')
# Native Windows Java emits CRLF; command substitution removes only LF.
output=${output%$'\r'}
[ "$output" = 'jvm real JDK smoke passed' ] || fail "unexpected program output: $output"

step 'offline uninstallation and default/staging cleanup'
jvm uninstall "$id"
[ ! -e "$home" ] && [ ! -L "$home" ] || fail 'uninstall left the installation behind'
for entry in "$XDG_DATA_HOME/jvm/jdks/"* "$XDG_DATA_HOME/jvm/tmp/"*; do
    [ ! -e "$entry" ] && [ ! -L "$entry" ] || fail "uninstall left storage entry: $entry"
done
[ "$(jvm list)" = "No JDKs are installed. Use 'install' to install one" ] || fail 'inventory is not empty'
[ "$(jvm default)" = 'No JDK currently set as the default' ] || fail 'default remains after uninstall'
[ ! -e "$JVM_SMOKE_REQUESTS" ] || fail 'offline checks attempted a network request'
[ ! -e "$XDG_CACHE_HOME" ] || fail 'offline checks recreated the metadata cache'
printf 'ok - real JDK download, default, offline reinstall, java/javac and uninstall (%s)\n' "$id"
