#!/usr/bin/env bash
# Unix CI/developer tooling only: build a private, real Bash 3.2 interpreter.
set -eu
[ "$#" -eq 1 ] || { echo 'Usage: bash tests/build-bash32.sh <new-build-directory>' >&2; exit 2; }
system=$(uname -s)
case "$system" in
    CYGWIN*|MSYS*|MINGW*)
        echo 'Bash 3.2 builds are supported only on Unix; Windows uses current Bash.' >&2
        exit 1 ;;
esac
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
# GCC 14+ diagnoses old C constructs as errors. These flags retain the original
# interpreter semantics while allowing its C sources to build with current GCC.
export CFLAGS='-O2 -std=gnu89 -fcommon -Wno-error=implicit-function-declaration -Wno-error=implicit-int'
export ac_cv_func_working_mktime=yes
# Use GCC's actual target tuple instead of the old config.guess database.
./configure --build="$(gcc -dumpmachine)" --prefix="$BUILD/install" \
    --without-bash-malloc --disable-nls > "$BUILD/configure.log" 2>&1 || {
    cat "$BUILD/configure.log" >&2
    exit 1
}
# Build serially: the old makefiles race when readline/history share objects.
# -fcommon above preserves the pre-GCC-10 handling of tentative definitions.
# Build only the interpreter; no system installation or documentation toolchain.
make -j1 CFLAGS_FOR_BUILD="$CFLAGS" YACC='bison -y' bash > "$BUILD/build.log" 2>&1 || {
    cat "$BUILD/build.log" >&2
    exit 1
}
mkdir "$BUILD/bin"
cp bash "$BUILD/bin/bash"
"$BUILD/bin/bash" -c '[ "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}" = 3.2 ]'
"$BUILD/bin/bash" --version
