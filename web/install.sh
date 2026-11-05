#!/usr/bin/env bash
# Standalone bootstrap. The Windows section is generated from install.ps1.
set -eu
VERSION='' PATH_CHOICE='' JAVA_CHOICE='' SHELL_CHOICE='' PROFILE='' NONINTERACTIVE=0
WORK='' LOCKED=0 PUBLISHED=0 STATE='' DEST='' DATA='' TX=''
SETUP_FILES=() SETUP_BACKUPS=() SETUP_EXISTED=()
say() { printf '%s\n' "jvm installer: $*" >&2; }
die() { say "$*"; exit 1; }
usage_error() { say "$*"; exit 2; }
help_text() {
    cat <<'EOF'
Install or update jvm in HOME/.local/bin (no JDK is installed).
Usage: install.sh [--version major.minor.patch]
  [--path | --no-path] [--java | --no-java]
  [--shell bash|zsh|fish|csh|tcsh] [--profile /absolute/file]
  [--non-interactive]
Explicit positive options consent to persistent environment edits.
Otherwise separate prompts default to no; unattended setup is skipped.
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
fetch_wget() {
    local url=$1 output=$2 status code location origin clean i=0
    # --https-only covers recursive links in GNU wget, not redirect targets.
    # Disable automatic redirects and validate every hop before requesting it.
    while [ "$i" -lt 10 ]; do
        case $url in https://*) ;; *) die 'wget redirect attempted an HTTPS downgrade' ;; esac
        status=0
        LC_ALL=C wget --max-redirect=0 --server-response --check-certificate --no-hsts --timeout=15 --tries=1 -O "$output" "$url" 2> "$WORK/wget-headers" || status=$?
        code=$(awk '/^[ \t]+HTTP\/[0-9.]+ [0-9]+/ {code=$2} END {print code}' "$WORK/wget-headers")
        if [ "$status" = 0 ] && [ "$code" = 200 ]; then return; fi
        case $code in 301|302|303|307|308) ;; *) die "wget download failed: $url (requires server-response/max-redirect support)" ;; esac
        location=$(awk 'tolower($0) ~ /^[ \t]+location:/ {v=$0; sub(/^[ \t]+[^:]+:[ \t]*/,"",v); sub(/\r$/,"",v)} END {print v}' "$WORK/wget-headers")
        case $location in ''|*' '*|*"$(printf '\t')"*|*"$(printf '\r')"*|*'
'*) die 'invalid wget redirect location' ;; esac
        clean=${url%%\#*}; clean=${clean%%\?*}
        origin=${clean#https://}; origin=${origin%%/*}
        case $location in
            [Hh][Tt][Tt][Pp][Ss]://*) url=https://${location#*://} ;;
            //*) url=https:$location ;;
            /*) url=https://$origin$location ;;
            \?*) url=$clean$location ;;
            \#*) url=${url%%\#*}$location ;;
            *:*) die 'wget redirect attempted a non-HTTPS URL' ;;
            *)
                case ${clean#https://} in */*) url=${clean%/*}/$location ;; *) url=$clean/$location ;; esac ;;
        esac
        i=$((i+1))
    done
    die 'too many wget redirects'
}
fetch() {
    case $DOWNLOADER in
        curl) curl -q --proto '=https' --proto-redir '=https' -fLsS --connect-timeout 15 --max-time 180 -o "$2" "$1" || die "download failed: $1" ;;
        wget) fetch_wget "$1" "$2" ;;
    esac
    [ -s "$2" ] || die "empty download: $1"
}
checksums() {
    LC_ALL=C awk '
      NF!=2 || length($1)!=64 || $1 ~ /[^0-9a-fA-F]/ {exit 1}
      $2!="jvm" && $2!="jvm.ps1" && $2!="jvm.cmd" {exit 1}
      seen[$2]++ {exit 1}
      END {if (NR!=3 || !seen["jvm"] || !seen["jvm.ps1"] || !seen["jvm.cmd"]) exit 1}
    ' "$1" || die 'invalid SHA256SUMS (expected exactly the three payload basenames)'
}
verify() {
    local expected actual
    expected=$(awk -v n="$2" '$2==n && length($1)==64 {print tolower($1)}' "$1")
    actual=$(hash "$3") || return 1
    [ "$expected" = "$actual" ]
}
plain_file() { [ -f "$1" ] && [ ! -L "$1" ]; }
read_record() {
    plain_file "$1" || die "unsafe ownership record: $1"
    [ "$(sed -n '1p' "$1")" = jvm-tool-v1 ] || die 'invalid ownership record'
    valid_version "$(sed -n '2p' "$1")" || die 'invalid owned version'
    [ "$(sed -n '3p' "$1")" = "$DEST" ] || die 'ownership destination mismatch'
    [ "$(wc -l < "$1" | tr -d ' ')" = 4 ] || die 'invalid ownership record length'
    tail -n 1 "$1" | LC_ALL=C grep -Eq '^[0-9a-f]{64}  jvm$' || die 'invalid ownership digest'
}
recover() {
    local entry
    [ ! -L "$TX" ] || die 'unsafe transaction directory'
    [ -d "$TX" ] || return 0
    for entry in "$TX/"* "$TX/".[!.]* "$TX/"..?*; do
        [ -e "$entry" ] || [ -L "$entry" ] || continue
        case ${entry##*/} in new-record|old-record|old-jvm|ready|published-record|restored-record) ;; *) die "Unrecognized recovery material: $entry; inspect manually" ;; esac
        plain_file "$entry" || die "Unsafe recovery material: $entry"
    done
    if [ -e "$DEST/.jvm-recover" ] || [ -L "$DEST/.jvm-recover" ]; then
        [ -e "$TX/ready" ] && plain_file "$DEST/.jvm-recover" || die 'recovery staging conflict; inspect .jvm-recover manually'
        rm "$DEST/.jvm-recover"
    fi
    if [ -e "$TX/ready" ]; then
        read_record "$TX/new-record"
        if [ -e "$TX/old-record" ]; then
            read_record "$TX/old-record"
            plain_file "$TX/old-jvm" && verify "$TX/old-record" jvm "$TX/old-jvm" || die 'recovery backup is damaged; preserve transaction for manual recovery'
            [ ! -e "$DEST/jvm" ] || plain_file "$DEST/jvm" || die 'unsafe recovery destination'
            cp -p "$TX/old-jvm" "$DEST/.jvm-recover" && mv -f "$DEST/.jvm-recover" "$DEST/jvm" || die 'could not restore tool; preserve transaction'
            cp "$TX/old-record" "$TX/restored-record" && mv -f "$TX/restored-record" "$STATE/record" || die 'could not restore ownership'
        else
            if [ -e "$DEST/jvm" ] || [ -L "$DEST/jvm" ]; then
                plain_file "$DEST/jvm" && verify "$TX/new-record" jvm "$DEST/jvm" || die 'unrecognized file during recovery; preserve transaction'
                rm "$DEST/jvm" || die 'could not remove interrupted publication'
            fi
            rm -f "$STATE/record"
        fi
        say 'Recovered interrupted tool publication.'
    fi
    if [ -e "$DEST/.jvm-next" ] || [ -L "$DEST/.jvm-next" ]; then
        plain_file "$DEST/.jvm-next" || die 'unsafe publication staging file'
        rm "$DEST/.jvm-next"
    fi
    rm -rf -- "$TX"
}
cleanup() {
    local status=$?
    trap - EXIT HUP INT TERM
    if [ "$status" != 0 ]; then
        local i=0 file backup
        for file in ${SETUP_FILES[@]+"${SETUP_FILES[@]}"}; do
            backup=${SETUP_BACKUPS[$i]}
            if [ "${SETUP_EXISTED[$i]}" = 1 ]; then
                cp -p "$backup" "$file" || say "Profile rollback failed: $file; exact backup: $backup"
            else rm -f "$file" || say "Could not remove new profile: $file"; fi
            i=$((i+1))
        done
    fi
    if [ "$LOCKED" = 1 ]; then
        if [ "$status" != 0 ] && [ -d "$TX" ]; then (recover) || say "Recovery retained at $TX; resolve it before retrying."; fi
        rm -f "$STATE/lock/pid"; rmdir "$STATE/lock" || :
    fi
    [ -z "$WORK" ] || rm -rf -- "$WORK"
    if [ "$status" != 0 ] && [ "$PUBLISHED" = 1 ]; then say 'Tool was installed; persistent environment setup failed.'; fi
    exit "$status"
}
lock() {
    if ! mkdir "$STATE/lock" 2>/dev/null; then
        [ -d "$STATE/lock" ] && [ ! -L "$STATE/lock" ] && plain_file "$STATE/lock/pid" || die "Unrecognized installer lock at $STATE/lock; inspect manually."
        local pid
        pid=$(cat "$STATE/lock/pid")
        case $pid in ''|*[!0-9]*) die 'invalid installer lock owner' ;; esac
        if ps -p "$pid" >/dev/null 2>&1; then die 'another installer is running; retry later'; fi
        die "Interrupted installer lock at $STATE/lock (recorded PID $pid). Confirm the process has exited, remove only lock/pid and the empty lock directory, then rerun to recover the transaction."
    fi
    LOCKED=1
    printf '%s\n' "$$" > "$STATE/lock/pid"
}
publish() {
    mkdir -p "$DEST" "$STATE"
    [ ! -L "$DEST" ] && [ ! -L "$STATE" ] || die 'destination/ownership directory must not be a symlink'
    lock
    recover
    if [ -e "$STATE/record" ] || [ -L "$STATE/record" ]; then
        read_record "$STATE/record"
        plain_file "$DEST/jvm" && verify "$STATE/record" jvm "$DEST/jvm" || die 'owned jvm is missing or locally modified; restore it or move it aside with the ownership record before retrying'
    elif [ -e "$DEST/jvm" ] || [ -L "$DEST/jvm" ]; then
        die "unowned destination conflict: $DEST/jvm; move it aside before retrying"
    fi
    if [ -f "$STATE/record" ] && [ "$(sed -n '2p' "$STATE/record")" = "$VERSION" ] && verify "$STATE/record" jvm "$WORK/jvm"; then
        PUBLISHED=1
        say "Already installed jvm $VERSION in $DEST"
        return
    fi
    [ ! -e "$DEST/.jvm-next" ] && [ ! -L "$DEST/.jvm-next" ] && [ ! -e "$DEST/.jvm-recover" ] && [ ! -L "$DEST/.jvm-recover" ] || die 'reserved staging filename exists in destination'
    mkdir "$TX"
    if [ -e "$STATE/record" ]; then
        cp "$STATE/record" "$TX/old-record"
        cp -p "$DEST/jvm" "$TX/old-jvm"
    fi
    { printf 'jvm-tool-v1\n%s\n%s\n' "$VERSION" "$DEST"; printf '%s  jvm\n' "$(hash "$WORK/jvm")"; } > "$TX/new-record"
    cp "$WORK/jvm" "$DEST/.jvm-next"
    chmod 755 "$DEST/.jvm-next"
    : > "$TX/ready"
    mv -f "$DEST/.jvm-next" "$DEST/jvm"
    cp "$TX/new-record" "$TX/published-record"
    mv -f "$TX/published-record" "$STATE/record"
    rm -rf -- "$TX"
    PUBLISHED=1
    say "Installed jvm $VERSION in $DEST"
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
consent() {
    [ "$1" != no ] || return 1
    [ "$1" != yes ] || return 0
    [ "$NONINTERACTIVE" = 0 ] && [ -r /dev/tty ] && [ -w /dev/tty ] || return 1
    local answer
    # Opening the controlling terminal may fail even when /dev/tty exists.
    { printf '%s [y/N] ' "$2" > /dev/tty; IFS= read -r answer < /dev/tty; } 2>/dev/null || return 1
    case $answer in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
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
    if cmp -s "$file" "$WORK/profile" 2>/dev/null; then rm -f "$tmp"; return; fi
    backup=$(mktemp "$file.jvm-backup.XXXXXXXX")
    if [ -e "$file" ]; then
        cp -p "$file" "$backup"
        SETUP_EXISTED+=( 1 )
    else : > "$backup"; SETUP_EXISTED+=( 0 ); fi
    SETUP_FILES+=( "$file" ) SETUP_BACKUPS+=( "$backup" )
    # Append/replace only the marked portion; retain original CRLF outside blocks.
    cat "$WORK/profile" > "$tmp" || die 'profile staging failed'
    if ! mv -f "$tmp" "$file"; then rm -f "$tmp"; die "profile publication failed; backup: $backup"; fi
    say "Updated $file; exact previous contents: $backup"
}
profile_correct() {
    local file=$1 kind=$2 value=$3
    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    validate_markers "$file" || return 1
    block "$kind" "$value" > "$WORK/expected"
    awk -v k="$kind" '$0=="# >>> jvm " k " >>>" {on=1} on {print} $0=="# <<< jvm " k " <<<" {on=0}' "$file" > "$WORK/actual"
    cmp -s "$WORK/expected" "$WORK/actual"
}
setup() {
    local files file login pc jc value kind correct
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
        value=$DEST; [ "$kind" != java ] || value=$JAVA_HOME_TARGET/bin
        correct=1
        for file in "${files[@]}"; do profile_correct "$file" "$kind" "$value" || correct=0; done
        [ "$correct" = 0 ] || continue
        say "Persistent $kind setup targets: ${files[*]}"
        if [ "$kind" = java ]; then say "JAVA_HOME: ${JAVA_HOME-<unset>} -> $JAVA_HOME_TARGET; PATH adds $value (a default JDK may not exist yet)."; else say "PATH adds $value (current membership does not establish persistence)."; fi
        if { [ "$kind" = path ] && consent "$pc" 'Configure persistent tool PATH?'; } || { [ "$kind" = java ] && consent "$jc" 'Configure persistent default Java?'; }; then
            for file in "${files[@]}"; do edit_profile "$file" "$kind" "$value"; done
            SETUP_FILES=() SETUP_BACKUPS=() SETUP_EXISTED=()
        else say "Skipped $kind setup. Manually configure the paths above if desired."; fi
    done
}
main() {
    local original host name converted powershell_bin system_directory
    # Preserve the original arguments for the embedded Windows entry point.
    original=("$@")
    parse "$@"
    host=$(uname -s)
    case $host in
        CYGWIN*|MSYS*|MINGW*)
            [ -z "$SHELL_CHOICE$PROFILE" ] || usage_error '--shell/--profile are Unix-only'
            command -v cygpath >/dev/null || die 'Windows Bash needs cygpath'
            if ! powershell_bin=$(command -v powershell.exe); then
                system_directory=$(cygpath -u -S) || die 'could not locate the Windows system directory'
                powershell_bin=$system_directory/WindowsPowerShell/v1.0/powershell.exe
            fi
            [ -f "$powershell_bin" ] || die 'Windows Bash needs Windows PowerShell'
            case ${HOME:-} in
                '') ;;
                /*|[A-Za-z]:[\\/]*|\\\\*)
                    converted=$(cygpath -aw "$HOME") || die 'could not convert HOME to a native path'
                    export HOME=$converted ;;
                *) die 'HOME must be absolute' ;;
            esac
            if [ -n "${XDG_DATA_HOME:-}" ]; then
                case $XDG_DATA_HOME in
                    /*|[A-Za-z]:[\\/]*|\\\\*)
                        converted=$(cygpath -aw "$XDG_DATA_HOME") || die 'could not convert XDG_DATA_HOME to a native path'
                        export XDG_DATA_HOME=$converted ;;
                    *) unset XDG_DATA_HOME ;;
                esac
            fi
            WORK=$(mktemp -d "${TMPDIR:-/tmp}/jvm-bootstrap.XXXXXXXX")
            trap cleanup EXIT; trap 'exit 1' HUP INT TERM
            windows_installer > "$WORK/install.ps1"
            local args arg
            args=()
            for arg in "${original[@]}"; do
                case $arg in --version) args+=( -Version ) ;; --path) args+=( -Path ) ;; --no-path) args+=( -NoPath ) ;; --java) args+=( -Java ) ;; --no-java) args+=( -NoJava ) ;; --non-interactive) args+=( -NonInteractive ) ;; *) args+=( "$arg" ) ;; esac
            done
            MSYS2_ARG_CONV_EXCL='*' "$powershell_bin" -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -aw "$WORK/install.ps1")" "${args[@]}"
            return ;;
        Linux|Darwin) ;; *) die "unsupported host: $host" ;;
    esac
    [ -n "${HOME:-}" ] || die 'HOME is required'
    safe_path "$HOME"
    DATA=${XDG_DATA_HOME:-$HOME/.local/share}
    case $DATA in /*) ;; *) DATA=$HOME/.local/share ;; esac
    safe_path "$DATA"
    DEST=$HOME/.local/bin STATE=$DATA/jvm/tool-install TX=$DATA/jvm/tool-install/transaction
    JAVA_HOME_TARGET=$DATA/jvm/jdks/default
    [ -z "$PROFILE" ] || safe_path "$PROFILE"
    DOWNLOADER='' HASHER=''
    for name in curl wget; do if command -v "$name" >/dev/null 2>&1; then DOWNLOADER=$name; break; fi; done
    for name in sha256sum shasum openssl; do if command -v "$name" >/dev/null 2>&1; then HASHER=$name; break; fi; done
    [ -n "$DOWNLOADER" ] && [ -n "$HASHER" ] || die 'need curl or HTTPS-capable wget and a SHA-256 utility'
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
    fetch "$url/SHA256SUMS" "$WORK/SHA256SUMS"
    checksums "$WORK/SHA256SUMS"
    fetch "$url/jvm" "$WORK/jvm"
    verify "$WORK/SHA256SUMS" jvm "$WORK/jvm" || die 'jvm checksum mismatch'
    publish
    setup
    say 'Open a fresh terminal application to inherit changes; later startup statements can override them.'
}
# BEGIN GENERATED WINDOWS INSTALLER
windows_installer() {
cat <<'JVM_POWERSHELL_INSTALLER'
# Windows PowerShell 5.1 standalone bootstrap. No JDK commands are invoked.
$ErrorActionPreference = 'Stop'

function Write-InstallerMessage([string]$Message) { [Console]::Error.WriteLine("jvm installer: $Message") }
function Stop-Installer([string]$Message, [int]$Code = 1) {
    $exception = New-Object Exception $Message
    $exception.Data['InstallerCode'] = $Code
    throw $exception
}
function Test-ToolVersion([string]$Value) { return $Value -cmatch '\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\z' }
function Get-ToolHash([string]$File) {
    $stream = [IO.File]::OpenRead($File)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose(); $stream.Dispose() }
}
function Test-PlainFile([string]$File) {
    if (-not [IO.File]::Exists($File)) { return $false }
    return -not ((Get-Item -LiteralPath $File -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)
}
function Assert-SafeRoot([string]$Value) {
    if ($Value -notmatch '\A(?:[A-Za-z]:[\\/]|\\\\[^\\/]+[\\/][^\\/]+)' -or $Value -match '[;\r\n\t]') {
        Stop-Installer "Expected an absolute native path without semicolons or line breaks: $Value"
    }
}
function Assert-NoReparse([string]$File) {
    if (Test-Path -LiteralPath $File) {
        if ((Get-Item -LiteralPath $File -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { Stop-Installer "Reparse point conflict: $File" }
    }
}
function Get-Download([string]$Url, [string]$File) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    for ($i = 0; $i -lt 10; $i++) {
        if (([Uri]$Url).Scheme -cne 'https') { Stop-Installer 'HTTPS is required, including redirects' }
        $request = [Net.HttpWebRequest]::Create($Url)
        $request.AllowAutoRedirect = $false
        $request.Timeout = 45000
        $request.ReadWriteTimeout = 45000
        $response = $request.GetResponse()
        try {
            $status = [int]$response.StatusCode
            if ($status -in @(301, 302, 303, 307, 308)) {
                $Url = ([Uri]::new([Uri]$Url, $response.Headers['Location'])).AbsoluteUri
                continue
            }
            if ($status -ne 200) { Stop-Installer "HTTP $status for $Url" }
            $inputStream = $response.GetResponseStream()
            $outputStream = [IO.File]::Create($File)
            try { $inputStream.CopyTo($outputStream) } finally { $outputStream.Dispose(); $inputStream.Dispose() }
            if ((Get-Item -LiteralPath $File).Length -eq 0) { Stop-Installer "Empty download: $Url" }
            return
        } finally { $response.Dispose() }
    }
    Stop-Installer 'Too many HTTPS redirects'
}
function Read-ToolChecksums([string]$File) {
    $result = @{}
    $lines = [IO.File]::ReadAllLines($File)
    if ($lines.Count -ne 3) { Stop-Installer 'SHA256SUMS must contain exactly three entries' }
    foreach ($line in $lines) {
        if ($line -cnotmatch '\A([0-9a-fA-F]{64})  (jvm|jvm\.ps1|jvm\.cmd)\z') { Stop-Installer 'Invalid SHA256SUMS entry' }
        $name = $Matches[2]; $digest = $Matches[1].ToLowerInvariant()
        if ($result.ContainsKey($name)) { Stop-Installer 'Duplicate SHA256SUMS entry' }
        $result[$name] = $digest
    }
    return $result
}
function Read-ToolRecord([string]$File, [string]$Destination) {
    if (-not (Test-PlainFile $File)) { Stop-Installer "Unsafe ownership record: $File" }
    $lines = [IO.File]::ReadAllLines($File)
    if ($lines.Count -ne 6 -or $lines[0] -cne 'jvm-tool-v1' -or -not (Test-ToolVersion $lines[1]) -or $lines[2] -cne $Destination) {
        Stop-Installer 'Invalid ownership record or destination mismatch'
    }
    $result = @{}
    foreach ($line in $lines[3..5]) {
        if ($line -cnotmatch '\A([0-9a-f]{64})  (jvm|jvm\.ps1|jvm\.cmd)\z' -or $result.ContainsKey($Matches[2])) { Stop-Installer 'Invalid ownership hashes' }
        $result[$Matches[2]] = $Matches[1]
    }
    return $result
}
function Write-ToolRecord([string]$File, [string]$Version, [string]$Destination, [hashtable]$Hashes) {
    $lines = @('jvm-tool-v1', $Version, $Destination)
    foreach ($name in @('jvm', 'jvm.ps1', 'jvm.cmd')) { $lines += "$($Hashes[$name])  $name" }
    [IO.File]::WriteAllText($File, (($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding $false))
}
function Remove-ToolStage([string]$Stage) {
    Assert-NoReparse $Stage
    if (-not (Test-Path -LiteralPath $Stage)) { return }
    foreach ($entry in @(Get-ChildItem -LiteralPath $Stage -Force)) {
        if ($entry.Name -cnotin @('jvm', 'jvm.ps1', 'jvm.cmd') -or -not (Test-PlainFile $entry.FullName)) { Stop-Installer "Unrecognized staging material: $($entry.FullName)" }
    }
    foreach ($entry in @(Get-ChildItem -LiteralPath $Stage -Force)) { [IO.File]::Delete($entry.FullName) }
    [IO.Directory]::Delete($Stage)
}
function Restore-ToolTransaction([string]$State, [string]$Destination) {
    $tx = Join-Path $State 'transaction'
    Assert-NoReparse $tx
    if (-not (Test-Path -LiteralPath $tx)) { return }
    foreach ($entry in @(Get-ChildItem -LiteralPath $tx -Force)) {
        if ($entry.Name -cnotin @('new-record', 'old-record', 'old-jvm', 'old-jvm.ps1', 'old-jvm.cmd', 'ready', 'stage-name') -or -not (Test-PlainFile $entry.FullName)) {
            Stop-Installer "Unrecognized recovery material: $($entry.FullName); inspect manually"
        }
    }
    if (Test-Path -LiteralPath (Join-Path $tx 'stage-name')) {
        if (-not (Test-PlainFile (Join-Path $tx 'stage-name'))) { Stop-Installer 'Unsafe staging journal' }
        $stageName = [IO.File]::ReadAllText((Join-Path $tx 'stage-name'))
        if ($stageName -cnotmatch '\A\.jvm-next-[a-f0-9]{32}\z') { Stop-Installer 'Invalid staging journal' }
        $stage = Join-Path $Destination $stageName
        Remove-ToolStage $stage
    }
    if (Test-Path -LiteralPath (Join-Path $tx 'ready')) {
        $new = Read-ToolRecord (Join-Path $tx 'new-record') $Destination
        $old = $null
        if (Test-Path -LiteralPath (Join-Path $tx 'old-record')) { $old = Read-ToolRecord (Join-Path $tx 'old-record') $Destination }
        # Verify every backup before restoring any member; recovery is repeatable.
        foreach ($name in @('jvm', 'jvm.ps1', 'jvm.cmd')) {
            $file = Join-Path $Destination $name
            Assert-NoReparse $file
            if ((Test-Path -LiteralPath $file) -and -not (Test-PlainFile $file)) { Stop-Installer "Unsafe recovery destination: $file" }
            if ($old) {
                $backup = Join-Path $tx "old-$name"
                if (-not (Test-PlainFile $backup) -or (Get-ToolHash $backup) -cne $old[$name]) { Stop-Installer "Damaged recovery material at $tx; inspect manually" }
            } elseif ((Test-Path -LiteralPath $file) -and (Get-ToolHash $file) -cne $new[$name]) { Stop-Installer "Unknown recovery destination: $file" }
        }
        foreach ($name in @('jvm', 'jvm.ps1', 'jvm.cmd')) {
            $file = Join-Path $Destination $name
            if ($old) {
                if (-not (Test-PlainFile $file) -or (Get-ToolHash $file) -cne $old[$name]) { [IO.File]::Copy((Join-Path $tx "old-$name"), $file, $true) }
            }
            elseif (Test-Path -LiteralPath $file) { [IO.File]::Delete($file) }
        }
        if ($old) { [IO.File]::Copy((Join-Path $tx 'old-record'), (Join-Path $State 'record'), $true) }
        elseif (Test-Path -LiteralPath (Join-Path $State 'record')) { [IO.File]::Delete((Join-Path $State 'record')) }
        Write-InstallerMessage 'Recovered interrupted tool publication.'
    }
    Remove-Item -LiteralPath $tx -Recurse -Force
}
function Publish-Tool([string]$Work, [string]$State, [string]$Destination, [string]$Version, [hashtable]$Hashes) {
    [IO.Directory]::CreateDirectory($Destination) | Out-Null
    [IO.Directory]::CreateDirectory($State) | Out-Null
    Assert-NoReparse $State; Assert-NoReparse $Destination
    Assert-NoReparse (Join-Path $State 'lock')
    try { $lock = [IO.File]::Open((Join-Path $State 'lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch { Stop-Installer 'Another installer holds the lock, or the lock is inaccessible; retry after it exits' }
    $tx = Join-Path $State 'transaction'
    try {
        Restore-ToolTransaction $State $Destination
        $record = Join-Path $State 'record'
        $old = $null
        Assert-NoReparse $record
        if (Test-Path -LiteralPath $record) { $old = Read-ToolRecord $record $Destination }
        foreach ($name in @('jvm', 'jvm.ps1', 'jvm.cmd')) {
            $file = Join-Path $Destination $name
            if ($old) {
                if (-not (Test-PlainFile $file) -or (Get-ToolHash $file) -cne $old[$name]) { Stop-Installer "Owned file missing or locally modified: $file. Restore it or move the payload and ownership record aside before retrying." }
            } elseif (Test-Path -LiteralPath $file) { Stop-Installer "Unowned destination conflict: $file. Move it aside before retrying." }
        }
        $matching = $null -ne $old
        if ($old) {
            $matching = ([IO.File]::ReadAllLines($record)[1] -ceq $Version)
            foreach ($name in @('jvm', 'jvm.ps1', 'jvm.cmd')) { if ($old[$name] -cne $Hashes[$name]) { $matching = $false } }
        }
        if ($matching) { return }
        [IO.Directory]::CreateDirectory($tx) | Out-Null
        if ($old) {
            [IO.File]::Copy($record, (Join-Path $tx 'old-record'))
            foreach ($name in @('jvm', 'jvm.ps1', 'jvm.cmd')) { [IO.File]::Copy((Join-Path $Destination $name), (Join-Path $tx "old-$name")) }
        }
        Write-ToolRecord (Join-Path $tx 'new-record') $Version $Destination $Hashes
        # Destination-filesystem staging, before any published file is changed.
        $next = Join-Path $Destination ('.jvm-next-' + [Guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText((Join-Path $tx 'stage-name'), [IO.Path]::GetFileName($next))
        [IO.Directory]::CreateDirectory($next) | Out-Null
        try {
            foreach ($name in @('jvm', 'jvm.ps1', 'jvm.cmd')) { [IO.File]::Copy((Join-Path $Work $name), (Join-Path $next $name)) }
            [IO.File]::WriteAllText((Join-Path $tx 'ready'), 'ready')
            foreach ($name in @('jvm', 'jvm.ps1', 'jvm.cmd')) {
                $file = Join-Path $Destination $name
                if ([IO.File]::Exists($file)) { [IO.File]::Delete($file) }
                [IO.File]::Move((Join-Path $next $name), $file)
            }
            [IO.File]::Copy((Join-Path $tx 'new-record'), $record, $true)
            Remove-Item -LiteralPath $tx -Recurse -Force
        } finally { Remove-ToolStage $next }
    } catch {
        $failure = $_
        try { Restore-ToolTransaction $State $Destination }
        catch { Write-InstallerMessage "Recovery retained at $tx. $($_.Exception.Message)" }
        throw $failure
    } finally {
        # Keep serialization through consented registry edits as well.
        $script:InstallerLock = $lock
    }
}
function Open-EnvironmentKey { return [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment') }
function Get-RegistryValue($Key, [string]$Name) {
    if ($Key.GetValueNames() -contains $Name) {
        return @{ Exists = $true; Kind = [int]$Key.GetValueKind($Name); Value = $Key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
    }
    return @{ Exists = $false; Kind = [int][Microsoft.Win32.RegistryValueKind]::ExpandString; Value = '' }
}
function Set-RegistrySnapshot($Key, [string]$Name, $Snapshot) {
    if ($Snapshot.Exists) { $Key.SetValue($Name, $Snapshot.Value, [Microsoft.Win32.RegistryValueKind]$Snapshot.Kind) }
    else { $Key.DeleteValue($Name, $false) }
}
function Test-PathEntry([string]$Entry, [string]$Target) {
    $expanded = [Environment]::ExpandEnvironmentVariables($Entry.Trim().Trim('"')).TrimEnd('\', '/')
    return $expanded.Replace('/', '\') -ieq $Target.TrimEnd('\', '/').Replace('/', '\')
}
function Add-UserPath([string]$Value, [string]$Entry) {
    foreach ($token in $Value.Split(';')) { if (Test-PathEntry $token $Entry) { return $Value } }
    if ([string]::IsNullOrEmpty($Value)) { return $Entry }
    return "$Entry;$Value"
}
function Send-EnvironmentChange {
    if (-not ('JvmInstaller.Native' -as [type])) {
        Add-Type @'
using System;
using System.Runtime.InteropServices;
namespace JvmInstaller { public static class Native {
  [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern IntPtr SendMessageTimeout(IntPtr h, uint m, UIntPtr w, string l, uint f, uint t, out UIntPtr r);
}}
'@
    }
    $result = [UIntPtr]::Zero
    [JvmInstaller.Native]::SendMessageTimeout([IntPtr]0xffff, 0x1a, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$result) | Out-Null
}
function Get-SetupConsent([string]$Choice, [bool]$Unattended, [string]$Prompt) {
    if ($Choice -eq 'yes') { return $true }
    if ($Choice -eq 'no' -or $Unattended -or [Console]::IsInputRedirected -or -not [Environment]::UserInteractive) { return $false }
    try { return (Read-Host "$Prompt [y/N]") -match '\A(?i:y|yes)\z' } catch { return $false }
}
function Set-UserEnvironment([string]$State, [string]$Destination, [string]$JavaHome, [string]$PathChoice, [string]$JavaChoice, [bool]$Unattended) {
    if ($PathChoice -eq 'no' -and $JavaChoice -eq 'no') { return }
    if ($Unattended -and $PathChoice -ne 'yes' -and $JavaChoice -ne 'yes') {
        Write-InstallerMessage "Unspecified environment setup skipped. Manual setup: user PATH adds $Destination; JAVA_HOME=$JavaHome and PATH adds its bin directory."
        return
    }
    $key = Open-EnvironmentKey
    try {
        $oldPath = Get-RegistryValue $key 'Path'
        $oldJava = Get-RegistryValue $key 'JAVA_HOME'
        foreach ($snapshot in @($oldPath, $oldJava)) {
            if ($snapshot.Exists -and $snapshot.Kind -notin @(1, 2)) { Stop-Installer 'Environment values must be REG_SZ or REG_EXPAND_SZ' }
        }
        $pathValue = [string]$oldPath.Value
        $toolPresent = (Add-UserPath $pathValue $Destination) -ceq $pathValue
        $javaBin = Join-Path $JavaHome 'bin'
        $javaPresent = $oldJava.Exists -and (Test-PathEntry ([string]$oldJava.Value) $JavaHome) -and ((Add-UserPath $pathValue $javaBin) -ceq $pathValue)
        $toolYes = $false; $javaYes = $false
        if (-not $toolPresent) {
            Write-InstallerMessage "HKCU\Environment\Path ($($oldPath.Kind)): add $Destination; preserve raw existing value: $pathValue"
            $toolYes = Get-SetupConsent $PathChoice $Unattended 'Persist tool PATH?'
        }
        if (-not $javaPresent) {
            Write-InstallerMessage "HKCU\Environment: JAVA_HOME '$($oldJava.Value)' -> '$JavaHome'; Path adds $javaBin. A default JDK may not exist yet."
            $javaYes = Get-SetupConsent $JavaChoice $Unattended 'Persist default Java?'
        }
        if (-not $toolYes -and -not $javaYes) {
            Write-InstallerMessage "Environment unchanged. Manual setup: user PATH adds $Destination; JAVA_HOME=$JavaHome and PATH adds $javaBin."
            return
        }
        if ($toolYes) { $pathValue = Add-UserPath $pathValue $Destination }
        if ($javaYes) { $pathValue = Add-UserPath $pathValue $javaBin }
        $backup = Join-Path $State ('environment-backup-' + [Guid]::NewGuid().ToString('N') + '.clixml')
        @{ Path = $oldPath; JAVA_HOME = $oldJava } | Export-Clixml -LiteralPath $backup -Encoding UTF8
        try {
            if ($javaYes) { $key.SetValue('JAVA_HOME', $JavaHome, [Microsoft.Win32.RegistryValueKind]$oldJava.Kind) }
            $key.SetValue('Path', $pathValue, [Microsoft.Win32.RegistryValueKind]$oldPath.Kind)
            $key.Flush()
            Send-EnvironmentChange
        } catch {
            $failure = $_
            try { Set-RegistrySnapshot $key 'Path' $oldPath; Set-RegistrySnapshot $key 'JAVA_HOME' $oldJava; $key.Flush() }
            catch { Write-InstallerMessage "Registry rollback failed; exact raw backup: $backup" }
            throw $failure
        }
        Write-InstallerMessage "Updated HKCU\Environment; raw value/type backup: $backup"
        $systemPath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        foreach ($entry in $systemPath.Split(';')) {
            $expanded = [Environment]::ExpandEnvironmentVariables($entry.Trim('"'))
            if (-not [IO.Path]::IsPathRooted($expanded)) { continue }
            if ([IO.File]::Exists([IO.Path]::Combine($expanded, 'java.exe'))) { Write-InstallerMessage "System Java at $expanded may precede user PATH. Machine PATH was preserved."; break }
        }
    } finally { $key.Dispose() }
}
function Invoke-JvmInstaller([string[]]$Arguments) {
    $version = ''; $pathChoice = 'ask'; $javaChoice = 'ask'; $unattended = $false
    $seen = @{}
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        $arg = $Arguments[$i]
        if ($arg -ieq '-Help') {
            if ($Arguments.Count -ne 1) { Stop-Installer '-Help must be used alone' 2 }
            Write-Output 'Usage: install.ps1 [-Version major.minor.patch] [-Path | -NoPath] [-Java | -NoJava] [-NonInteractive]'
            return
        }
        $group = $arg.ToLowerInvariant()
        if ($group -in @('-path', '-nopath')) { $group = 'path' }
        if ($group -in @('-java', '-nojava')) { $group = 'java' }
        if ($seen.ContainsKey($group)) { Stop-Installer "Duplicate/conflicting option: $arg" 2 }
        $seen[$group] = $true
        switch ($arg.ToLowerInvariant()) {
            '-version' { $i++; if ($i -ge $Arguments.Count -or -not (Test-ToolVersion $Arguments[$i])) { Stop-Installer 'Version must be numeric major.minor.patch without leading zeros' 2 }; $version = $Arguments[$i] }
            '-path' { $pathChoice = 'yes' }
            '-nopath' { $pathChoice = 'no' }
            '-java' { $javaChoice = 'yes' }
            '-nojava' { $javaChoice = 'no' }
            '-noninteractive' { $unattended = $true }
            default { Stop-Installer "Unknown option: $arg" 2 }
        }
    }
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { Stop-Installer 'The native installer supports Windows only' }
    $userHome = $env:HOME
    if ([string]::IsNullOrEmpty($userHome)) { $userHome = $env:USERPROFILE }
    Assert-SafeRoot $userHome
    $userHome = [IO.Path]::GetFullPath($userHome)
    $data = $env:XDG_DATA_HOME
    if ([string]::IsNullOrEmpty($data) -or $data -notmatch '\A(?:[A-Za-z]:[\\/]|\\\\[^\\/]+[\\/][^\\/]+)') { $data = Join-Path $userHome '.local\share' }
    Assert-SafeRoot $data
    $data = [IO.Path]::GetFullPath($data)
    $destination = Join-Path $userHome '.local\bin'
    $state = Join-Path $data 'jvm\tool-install'
    $javaHome = Join-Path $data 'jvm\jdks\default'
    $work = Join-Path ([IO.Path]::GetTempPath()) ('jvm-bootstrap-' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($work) | Out-Null
    $published = $false
    try {
        if (-not $version) {
            Get-Download 'https://getjvm.dev/latest.txt' (Join-Path $work 'latest.txt')
            $raw = [IO.File]::ReadAllText((Join-Path $work 'latest.txt'))
            if ($raw -cnotmatch '\A((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))\n?\z') { Stop-Installer 'Invalid latest.txt version' }
            $version = $Matches[1]
        }
        $base = "https://github.com/codejive/jvm/releases/download/v$version"
        Get-Download "$base/SHA256SUMS" (Join-Path $work 'SHA256SUMS')
        $hashes = Read-ToolChecksums (Join-Path $work 'SHA256SUMS')
        foreach ($name in @('jvm', 'jvm.ps1', 'jvm.cmd')) {
            Get-Download "$base/$name" (Join-Path $work $name)
            if ((Get-ToolHash (Join-Path $work $name)) -cne $hashes[$name]) { Stop-Installer "Checksum mismatch: $name" }
        }
        Publish-Tool $work $state $destination $version $hashes
        $published = $true
        Write-InstallerMessage "Installed jvm $version in $destination"
        Set-UserEnvironment $state $destination $javaHome $pathChoice $javaChoice $unattended
        Write-InstallerMessage 'Open a fresh terminal application/IDE; existing hosts may retain old values. Bash startup files may override inherited PATH; use cygpath -u for native paths there.'
    } catch {
        if ($published) { Write-InstallerMessage 'Tool was installed; persistent environment setup failed.' }
        throw
    } finally {
        if ($script:InstallerLock) { $script:InstallerLock.Dispose(); $script:InstallerLock = $null }
        Remove-Item -LiteralPath $work -Recurse -Force
    }
}

try { Invoke-JvmInstaller @($args) }
catch {
    Write-InstallerMessage $_.Exception.Message
    $code = 1
    if ($_.Exception.Data.Contains('InstallerCode')) { $code = [int]$_.Exception.Data['InstallerCode'] }
    exit $code
}
JVM_POWERSHELL_INSTALLER
}
main "$@"
