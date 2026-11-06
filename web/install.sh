#!/usr/bin/env bash
# MIT License
#
# Copyright (c) 2026 Tako Schotanus
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

# Standalone Bash bootstrap; persistent setup uses shell profiles on every host.
set -eu
VERSION='' PATH_CHOICE='' JAVA_CHOICE='' SHELL_CHOICE='' PROFILE='' NONINTERACTIVE=0
WORK='' INSTALLED=0 DEST='' DATA='' ENV_CHANGED=0 MODE=''
FILES=(jvm)
SETUP_FILES=() SETUP_BACKUPS=() SETUP_EXISTED=()
say() { printf '%s\n' "jvm installer: $*" >&2; }
die() { say "$*"; exit 1; }
usage_error() { say "$*"; exit 2; }
help_text() {
    cat <<'EOF'
Install or update jvm locally or in HOME/.local/bin (no JDK is installed).
Usage: install.sh [--version major.minor.patch]
  [--local | --user]
  [--path | --no-path] [--java | --no-java]
  [--shell bash|zsh|fish|csh|tcsh] [--profile /absolute/file]
  [--non-interactive]
Explicit positive options consent to persistent environment edits.
Otherwise separate prompts default to yes; unattended setup is skipped.
Local installation copies all three scripts to the current directory, without setup.
Without a terminal, user installation remains the default.
EOF
}
valid_version() {
    case $1 in ''|*[!0-9.]*) return 1 ;; esac
    printf '%s\n' "$1" | LC_ALL=C grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
}
parse() {
    while [ "$#" -gt 0 ]; do
        case $1 in
            --help) [ "$#" = 1 ] || usage_error '--help must be used alone'; help_text; exit 0 ;;
            --version|--shell|--profile)
                [ "$#" -ge 2 ] && [ -n "$2" ] || usage_error "$1 requires a value"
                case $1 in
                    --version) [ -z "$VERSION" ] || usage_error 'duplicate version'; VERSION=$2 ;;
                    --shell) [ -z "$SHELL_CHOICE" ] || usage_error 'duplicate shell'; SHELL_CHOICE=$2 ;;
                    --profile) [ -z "$PROFILE" ] || usage_error 'duplicate profile'; PROFILE=$2 ;;
                esac; shift ;;
            --path|--no-path) [ -z "$PATH_CHOICE" ] || usage_error 'conflicting/duplicate PATH options'; PATH_CHOICE=$1 ;;
            --local|--user) [ -z "$MODE" ] || usage_error 'conflicting/duplicate installation options'; MODE=${1#--} ;;
            --java|--no-java) [ -z "$JAVA_CHOICE" ] || usage_error 'conflicting/duplicate Java options'; JAVA_CHOICE=$1 ;;
            --non-interactive) [ "$NONINTERACTIVE" = 0 ] || usage_error 'duplicate non-interactive'; NONINTERACTIVE=1 ;;
            *) usage_error "unknown option: $1" ;;
        esac; shift
    done
    [ -z "$VERSION" ] || valid_version "$VERSION" || usage_error 'invalid version (expected major.minor.patch)'
    case $SHELL_CHOICE in ''|bash|zsh|fish|csh|tcsh) ;; *) usage_error 'unsupported shell' ;; esac
    if [ -n "$PROFILE" ]; then
        [ -n "$SHELL_CHOICE" ] || usage_error '--profile requires --shell'
        case $PROFILE in /*) ;; *) usage_error 'profile must be absolute' ;; esac
    fi
}
safe_path() {
    case $1 in /*) ;; *) die "absolute path required: $1" ;; esac
    case $1 in *:*|*';'*|*"$(printf '\r')"*|*'
'*|*"$(printf '\t')"*) die "unrepresentable path: $1" ;; esac
}
hash() {
    case $HASHER in
        sha256sum) sha256sum < "$1" ;;
        shasum) shasum -a 256 < "$1" ;;
        openssl) openssl dgst -sha256 < "$1" ;;
    esac | awk '{v=(length($1)==64 ? $1 : $NF); if(length(v)==64 && v !~ /[^0-9a-fA-F]/) {print tolower(v); found++}} END {if(found!=1) exit 1}'
}
fetch() {
    case $DOWNLOADER in
        curl) curl -q --proto '=https' --proto-redir '=https' -fLsS --connect-timeout 15 --max-time 180 -o "$2" "$1" || die "download failed: $1" ;;
        wget) wget --timeout=15 --tries=1 -O "$2" "$1" || die "download failed: $1" ;;
    esac
    [ -s "$2" ] || die "empty download: $1"
}
unpack() {
    local expected actual
    expected=$(LC_ALL=C awk 'length($0)!=64 || /[^0-9a-fA-F]/ {exit 1}
        {print tolower($0)} END {if(NR!=1) exit 1}' "$WORK/jvm.tar.gz.sha256") || die 'invalid archive checksum'
    actual=$(hash "$WORK/jvm.tar.gz") || die 'could not hash archive'
    [ "$expected" = "$actual" ] || die 'archive checksum mismatch'
    TAR_OPTIONS='' tar -xzf "$WORK/jvm.tar.gz" -C "$WORK" || die 'archive extraction failed'
}
plain_file() { [ -f "$1" ] && [ ! -L "$1" ]; }
cleanup() {
    local status=$?
    trap - EXIT HUP INT TERM
    if [ "$status" != 0 ]; then
        local i=0 file backup
        for file in ${SETUP_FILES[@]+"${SETUP_FILES[@]}"}; do
            backup=${SETUP_BACKUPS[$i]}
            if [ "${SETUP_EXISTED[$i]}" = 1 ]; then
                cp -p "$backup" "$file" || say "Profile rollback failed: $file"
            else rm -f "$file" || say "Could not remove new profile: $file"; fi
            i=$((i+1))
        done
    fi
    [ -z "$WORK" ] || rm -rf -- "$WORK"
    if [ "$status" != 0 ] && [ "$INSTALLED" = 1 ]; then say 'Tool was installed; persistent environment setup failed.'; fi
    exit "$status"
}
quote() {
    case ${SHELL_CHOICE:-} in
        fish) printf "'%s'" "$(printf '%s' "$1" | sed "s/\\\\/\\\\\\\\/g; s/'/\\\\'/g")" ;;
        csh|tcsh)
            # Keep command/variable metacharacters inside single quotes. Use a
            # double-quoted apostrophe between segments; history needs \! even
            # inside single quotes in interactive C shells.
            printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\"'\"'/g; s/!/\\\\!/g")" ;;
        *) printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;;
    esac
}
setup_answer_yes() {
    case $1 in ''|y|Y|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}
choose_installation() {
    [ -z "$MODE" ] || return 0
    MODE=user
    [ "$NONINTERACTIVE" = 0 ] && [ -r /dev/tty ] && [ -w /dev/tty ] || return 0
    local answer
    while :; do
        { printf '\nHow would you like to install jvm?\n\n1. Install locally\n   Copy all three jvm scripts to the current directory, without changing your\n   environment. Useful for including jvm in a Java project.\n\n2. Install for your user\n   Install jvm in HOME/.local/bin, with optional PATH and JAVA_HOME setup.\n   Useful for keeping jvm available across projects.\n\nChoose [1/2] (default: 2): ' > /dev/tty
          IFS= read -r answer < /dev/tty; } 2>/dev/null || return 0
        case $answer in 1) MODE=local; return 0 ;; ''|2) return 0 ;; esac
        say 'Please enter 1 or 2.'
    done
}
consent() {
    [ "$1" != no ] || return 1
    [ "$1" != yes ] || return 0
    [ "$NONINTERACTIVE" = 0 ] && [ -r /dev/tty ] && [ -w /dev/tty ] || return 1
    local answer
    # Opening the controlling terminal may fail even when /dev/tty exists.
    { printf '%s [Y/n] ' "$2" > /dev/tty; IFS= read -r answer < /dev/tty; } 2>/dev/null || return 1
    setup_answer_yes "$answer"
}
block() {
    local kind=$1 value=$2 q
    q=$(quote "$value")
    printf '# >>> jvm %s >>>\n' "$kind"
    case $SHELL_CHOICE in
        bash|zsh)
            [ "$kind" != java ] || printf 'export JAVA_HOME=%s\n' "$(quote "$JAVA_HOME_TARGET")"
            printf 'case ":${PATH-}:" in *:%s:*) ;; *) export PATH=%s${PATH+:"$PATH"} ;; esac\n' "$q" "$q" ;;
        fish)
            if [ "$kind" = java ]; then printf 'set -gx JAVA_HOME %s\n' "$(quote "$JAVA_HOME_TARGET")"; fi
            printf 'if not contains -- %s $PATH\n    set -gx PATH %s $PATH\nend\n' "$q" "$q" ;;
        csh|tcsh)
            [ "$kind" != java ] || printf 'setenv JAVA_HOME %s\n' "$(quote "$JAVA_HOME_TARGET")"
            # BSD csh's foreach stores each item with set(), which re-expands
            # backticks after the list's quote flags have been stripped. Read
            # existing entries by index instead, preserving :q through comparison.
            printf 'if ( ! $?path ) then\n    set path = ()\nendif\nset jvm_present = 0\n@ jvm_index = 1\nwhile ( $jvm_index <= $#path )\n    if ( $path[$jvm_index]:q == %s ) then\n        set jvm_present = 1\n    endif\n    @ jvm_index++\nend\nif ( $jvm_present == 0 ) then\n    set path = ( %s $path:q )\nendif\nunset jvm_present jvm_index\n' "$q" "$q" ;;
    esac
    printf '# <<< jvm %s <<<\n' "$kind"
}
validate_markers() {
    awk '
      /^# >>> jvm (path|java) >>>$/ {if (active || seen[$0]++) exit 1; active=$0; next}
      /^# <<< jvm (path|java) <<<$/{expected=$0; sub("<<<",">>>",expected); sub("<<<$",">>>",expected); if(active!=expected) exit 1; active=""; next}
      /jvm (path|java) (>>>|<<<)/ {exit 1}
      END {if(active) exit 1}
    ' "$1"
}
edit_profile() {
    local file=$1 kind=$2 value=$3 backup tmp
    safe_path "$file"
    [ ! -L "$file" ] || die "symlinked profile: $file; use --profile with its explicit target"
    if [ -e "$file" ]; then plain_file "$file" || die "profile is not a regular file: $file"; fi
    if [ "${FISH_MANAGED:-0}" = 1 ] && [ -e "$file" ] && ! grep -q '^# >>> jvm ' "$file"; then die "unowned Fish configuration: $file"; fi
    if profile_correct "$file" "$kind" "$value"; then return; fi
    mkdir -p "$(dirname "$file")"
    tmp=$(mktemp "$(dirname "$file")/.jvm-profile.XXXXXXXX")
    if [ -e "$file" ]; then cp -p "$file" "$tmp"; else : > "$tmp"; fi
    # Validate both block types before replacing either, preserving all outside bytes.
    validate_markers "$tmp" || { rm -f "$tmp"; die "corrupt/duplicate managed markers in $file"; }
    block "$kind" "$value" > "$WORK/block"
    # Avoid rewriting a correct block (and avoid repeated prompts via profile_correct).
    awk -v k="$kind" '
      $0=="# >>> jvm " k " >>>" {skip=1}
      !skip {print}
      $0=="# <<< jvm " k " <<<" {skip=0}
    ' "$tmp" > "$WORK/profile"
    cat "$WORK/block" >> "$WORK/profile"
    backup=$(mktemp "$WORK/profile-backup.XXXXXXXX")
    if [ -e "$file" ]; then
        cp -p "$file" "$backup"
        SETUP_EXISTED+=( 1 )
    else : > "$backup"; SETUP_EXISTED+=( 0 ); fi
    SETUP_FILES+=( "$file" ) SETUP_BACKUPS+=( "$backup" )
    # Append/replace only the marked portion; retain original CRLF outside blocks.
    cat "$WORK/profile" > "$tmp" || die 'profile staging failed'
    if ! mv -f "$tmp" "$file"; then rm -f "$tmp"; die "profile update failed: $file"; fi
    say "Updated $file"
}
profile_correct() {
    local file=$1 kind=$2 value=$3 expected actual
    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    validate_markers "$file" || return 1
    expected=$(block "$kind" "$value") || return 1
    actual=$(awk -v k="$kind" '$0=="# >>> jvm " k " >>>" {on=1} on {print} $0=="# <<< jvm " k " <<<" {on=0}' "$file") || return 1
    [ "$expected" = "$actual" ]
}
setup() {
    local files file login pc jc value kind correct introduced=0
    if [ "$NONINTERACTIVE" = 1 ]; then
        if [ -z "$PATH_CHOICE" ]; then PATH_CHOICE=--no-path; say "Tool PATH setup skipped; manually add $DEST to PATH if desired."; fi
        if [ -z "$JAVA_CHOICE" ]; then JAVA_CHOICE=--no-java; say "Java setup skipped; manually set JAVA_HOME=$JAVA_HOME_TARGET and add its bin to PATH if desired."; fi
    fi
    if [ "$PATH_CHOICE" = --no-path ] && [ "$JAVA_CHOICE" = --no-java ]; then return; fi
    if [ -z "$SHELL_CHOICE" ]; then SHELL_CHOICE=${SHELL:-}; SHELL_CHOICE=${SHELL_CHOICE##*/}; fi
    files=()
    if [ -n "$PROFILE" ]; then files=("$PROFILE"); else
        case $SHELL_CHOICE in
            bash)
                login=$HOME/.profile
                for file in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
                    if [ -f "$file" ] && [ -r "$file" ]; then login=$file; break; fi
                done
                files=("$HOME/.bashrc" "$login") ;;
            zsh) files=("${ZDOTDIR:-$HOME}/.zshrc") ;;
            fish)
                file=${XDG_CONFIG_HOME:-$HOME/.config}
                case $file in /*) ;; *) file=$HOME/.config ;; esac
                files=("$file/fish/conf.d/jvm.fish")
                FISH_MANAGED=1 ;;
            csh) files=("$HOME/.cshrc") ;;
            tcsh) if [ -e "$HOME/.tcshrc" ]; then files=("$HOME/.tcshrc"); else files=("$HOME/.cshrc"); fi ;;
            *)
                [ "$PATH_CHOICE" != --path ] && [ "$JAVA_CHOICE" != --java ] || die 'requested setup needs --shell and optionally --profile'
                say "Unknown shell; add $DEST to PATH; JAVA_HOME=$JAVA_HOME_TARGET and add its bin directory to PATH."; return ;;
        esac
    fi
    pc=ask jc=ask
    case $PATH_CHOICE in --path) pc=yes ;; --no-path) pc=no ;; esac
    case $JAVA_CHOICE in --java) jc=yes ;; --no-java) jc=no ;; esac
    for kind in path java; do
        if [ "$kind" = path ] && [ "$pc" = no ]; then continue; fi
        if [ "$kind" = java ] && [ "$jc" = no ]; then continue; fi
        value=$DEST; [ "$kind" != java ] || value=$JAVA_BIN_TARGET
        correct=1
        for file in "${files[@]}"; do profile_correct "$file" "$kind" "$value" || correct=0; done
        [ "$correct" = 0 ] || continue
        if [ "$introduced" = 0 ]; then
            printf "\nLet's set up jvm for future terminals.\nThe optional settings below update these shell startup files:\n" >&2
            printf '  %s\n' "${files[@]}" >&2
            introduced=1
        fi
        if [ "$kind" = java ]; then
            printf "\nUse jvm's default JDK for Java commands?\n\nSets JAVA_HOME to %s\n(current value: %s)\nand adds its bin directory to PATH.\n\nYes: configure future terminals to use jvm's default JDK.\n" "$JAVA_HOME_TARGET" "${JAVA_HOME-<unset>}" >&2
        else
            printf '\nRun jvm from any directory?\n\nAdds %s to PATH.\n\nYes: enable the jvm command in future terminals.\n' "$value" >&2
        fi
        printf 'No:  leave your environment settings unchanged.\n\n' >&2
        if { [ "$kind" = path ] && consent "$pc" 'Enable this?'; } || { [ "$kind" = java ] && consent "$jc" 'Enable this?'; }; then
            for file in "${files[@]}"; do edit_profile "$file" "$kind" "$value"; done
            SETUP_FILES=() SETUP_BACKUPS=() SETUP_EXISTED=()
            ENV_CHANGED=1
        else say "Skipped $kind setup. Manually configure the paths above if desired."; fi
    done
}
# Inspect managed inventory only; do not execute Java or the downloaded tool.
installed_jdk() {
    local directory id name suffix found
    [ -d "$DATA/jvm/jdks" ] || return 1
    if [ ! -r "$DATA/jvm/jdks" ] || [ ! -x "$DATA/jvm/jdks" ]; then
        say 'Could not check installed JDKs: inventory is not readable.'
        return 0
    fi
    for directory in "$DATA/jvm/jdks/"* "$DATA/jvm/jdks/".[!.]* "$DATA/jvm/jdks/"..?*; do
        [ -d "$directory" ] && [ ! -L "$directory" ] || continue
        id=${directory##*/}
        [ "${#id}" -le 180 ] || continue
        case $id in default|-*|*\\*|*[$'\t\r\n']*) continue ;; esac
        [[ ! $id =~ ^[0-9]+$ ]] || continue
        for name in java javac; do
            found=0
            for suffix in '' .exe .bat .cmd; do
                if [ "$windows" = 1 ]; then
                    [ ! -f "$directory/bin/$name$suffix" ] || found=1
                elif [ -f "$directory/bin/$name" ] && [ -x "$directory/bin/$name" ]; then found=1; fi
            done
            [ "$found" = 1 ] || break
        done
        [ "$found" != 1 ] || return 0
    done
    return 1
}
main() {
    local host name windows=0
    parse "$@"
    choose_installation
    host=$(uname -s)
    case $host in
        CYGWIN*|MSYS*|MINGW*)
            windows=1
            FILES=(jvm jvm.ps1 jvm.cmd)
            command -v cygpath >/dev/null || die 'Windows Bash needs cygpath'
            case ${HOME:-} in
                [A-Za-z]:[\\/]*|\\\\*) HOME=$(cygpath -au "$HOME") || die 'could not convert HOME' ;;
            esac
            case ${XDG_DATA_HOME:-} in
                [A-Za-z]:[\\/]*|\\\\*) XDG_DATA_HOME=$(cygpath -au "$XDG_DATA_HOME") || die 'could not convert XDG_DATA_HOME' ;;
            esac ;;
        Linux|Darwin) ;; *) die "unsupported host: $host" ;;
    esac
    [ -n "${HOME:-}" ] || die 'HOME is required'
    safe_path "$HOME"
    DATA=${XDG_DATA_HOME:-$HOME/.local/share}
    case $DATA in /*) ;; *) DATA=$HOME/.local/share ;; esac
    safe_path "$DATA"
    DEST=$HOME/.local/bin
    if [ "$MODE" = local ]; then
        DEST=$(pwd -P) || die 'could not resolve current directory'
        FILES=(jvm jvm.ps1 jvm.cmd)
    fi
    JAVA_HOME_TARGET=$DATA/jvm/jdks/default
    JAVA_BIN_TARGET=$JAVA_HOME_TARGET/bin
    if [ "$windows" = 1 ]; then
        JAVA_HOME_TARGET=$(cygpath -am "$JAVA_HOME_TARGET") || die 'could not convert JAVA_HOME'
    fi
    [ -z "$PROFILE" ] || safe_path "$PROFILE"
    DOWNLOADER='' HASHER=''
    for name in curl wget; do if command -v "$name" >/dev/null 2>&1; then DOWNLOADER=$name; break; fi; done
    for name in sha256sum shasum openssl; do if command -v "$name" >/dev/null 2>&1; then HASHER=$name; break; fi; done
    [ -n "$DOWNLOADER" ] && [ -n "$HASHER" ] || die 'need curl or wget and a SHA-256 utility'
    command -v tar >/dev/null 2>&1 || die 'tar with gzip support is required'
    umask 077
    WORK=$(mktemp -d "${TMPDIR:-/tmp}/jvm-bootstrap.XXXXXXXX")
    trap cleanup EXIT; trap 'exit 1' HUP INT TERM
    if [ -z "$VERSION" ]; then
        fetch https://getjvm.dev/latest.txt "$WORK/latest"
        [ "$(wc -l < "$WORK/latest" | tr -d ' ')" -le 1 ] || die 'invalid latest.txt'
        VERSION=$(cat "$WORK/latest")
        valid_version "$VERSION" || die 'invalid latest.txt version'
    fi
    local url
    url=https://github.com/codejive/jvm/releases/download/v$VERSION
    fetch "$url/jvm.tar.gz.sha256" "$WORK/jvm.tar.gz.sha256"
    fetch "$url/jvm.tar.gz" "$WORK/jvm.tar.gz"
    unpack
    mkdir -p "$DEST"
    for name in "${FILES[@]}"; do
        cp "$WORK/$name" "$DEST/$name" || die "could not copy $name to $DEST"
    done
    chmod 755 "$DEST/jvm"
    INSTALLED=1
    say "jvm $VERSION installed successfully in $DEST."
    if [ "$MODE" = user ]; then setup; fi
    local invocation=jvm
    [ "$MODE" != local ] || invocation=./jvm
    if installed_jdk; then
        printf '\nSee your currently installed JDKs with:\n  %s list\n' "$invocation" >&2
    else
        printf '\nNo JDK is installed yet. Install one with:\n  %s install\n' "$invocation" >&2
    fi
    say 'Setup complete.'
    if [ "$ENV_CHANGED" = 1 ]; then say 'Open a new terminal application to use your changes.'; fi
}
main "$@"
