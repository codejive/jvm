#!/usr/bin/env bash
# CI/developer tooling only: build a private, real Bash 3.2 interpreter.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
[ "$#" -eq 1 ] || { echo 'Usage: bash tests/build-bash32.sh <new-build-directory>' >&2; exit 2; }
mkdir -- "$1"
BUILD=$(cd "$1" && pwd -P)
cd "$BUILD"
curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    --connect-timeout 10 --max-time 120 --output bash.tar.gz \
    https://ftp.gnu.org/gnu/bash/bash-3.2.57.tar.gz
# GNU's complete patchlevel-57 release; verify before extracting/building.
printf '%s  bash.tar.gz\n' 3fa9daf85ebf35068f090ce51283ddeeb3c75eb5bc70b1a4a7cb05868bfe06a4 | sha256sum -c -
tar -xzf bash.tar.gz
cd bash-3.2.57
case "$(uname -s)" in CYGWIN*) program=bash.exe ;; *) program=bash ;; esac
# GCC 14+ diagnoses old C constructs as errors. These flags retain the original
# interpreter semantics while allowing its C sources to build with current GCC.
export CFLAGS='-O2 -std=gnu89 -fcommon -Wno-error=implicit-function-declaration -Wno-error=implicit-int'
case "$(uname -s)" in
    CYGWIN*)
        # Modern Cygwin maps setmode to _setmode in io.h and has removed the
        # old path conversion API. Adapt only the private test interpreter.
        CFLAGS="$CFLAGS -include io.h"
        patch -p1 < "$ROOT/tests/bash32-cygwin.patch"
        ;;
esac
export ac_cv_func_working_mktime=yes
# The 2006 config.guess predates x86_64 Cygwin; use GCC's actual target tuple.
./configure --build="$(gcc -dumpmachine)" --prefix="$BUILD/install" \
    --without-bash-malloc --disable-nls > "$BUILD/configure.log" 2>&1 || {
    cat "$BUILD/configure.log" >&2
    exit 1
}
# Build serially: the old makefiles race when readline/history share objects.
# -fcommon above preserves the pre-GCC-10 handling of tentative definitions.
# Build only the interpreter; no system installation or documentation toolchain.
make -j1 CFLAGS_FOR_BUILD="$CFLAGS" YACC='bison -y' "$program" > "$BUILD/build.log" 2>&1 || {
    cat "$BUILD/build.log" >&2
    exit 1
}
mkdir "$BUILD/bin"
cp "$program" "$BUILD/bin/$program"
case "$(uname -s)" in
    CYGWIN*)
        # The offline harness intentionally removes /usr/bin from PATH. Keep
        # Bash's supporting Cygwin DLLs beside the private executable so that
        # loader lookup does not require exposing real utilities to the tests.
        # Keep using the installed cygwin1.dll, not a second Cygwin runtime.
        cygcheck "$BUILD/bin/$program" > "$BUILD/dependencies.log"
        sed 's/^[[:space:]]*//; s/\r$//' "$BUILD/dependencies.log" > "$BUILD/dependencies.paths"
        while IFS= read -r dependency; do
            case "$dependency" in
                *cygwin1.dll) ;;
                *cyg*.dll)
                    dependency=$(cygpath -u "$dependency")
                    cp "$dependency" "$BUILD/bin/" ;;
            esac
        done < "$BUILD/dependencies.paths"
        ;;
esac
# Catch loader failures here rather than at the first isolated test wrapper.
PATH= "$BUILD/bin/bash" -c '[ "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}" = 3.2 ]'
"$BUILD/bin/bash" -c '[ "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}" = 3.2 ]'
"$BUILD/bin/bash" --version
