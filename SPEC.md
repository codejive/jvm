# jvm specification

`jvm` is a small command line tool for obtaining and selecting Java Development
Kits (JDKs). Projects commit a copy of the tool and invoke it directly; no
separate JDK manager is needed. Downloads and user preferences are shared by all
project copies. This document describes the current behavior of both
implementations: the Bash script `jvm` and the native Windows PowerShell 5.1
script `jvm.ps1`. Verification procedures and results live in
[tests/README.md](tests/README.md).

## Commands

```text
jvm --help
jvm --version
jvm available [-t] [selector]
jvm list [selector]
jvm install [-d] [-v] [selector]
jvm uninstall <selector>
jvm default
jvm default <major>
jvm default set <selector>
jvm default set <major> <selector>
jvm home [selector]
jvm env [-f] [selector]
jvm exec <selector> [--] <command> [args...]
```

Single-letter aliases behave exactly like their commands: `a` available, `l`
list, `i` install, `u` uninstall, `d` default, `h` home, `e` env, `x` exec. There
is no `help`, `shell` or `s` command; unknown commands exit 2. `--help` (also as
a command's only argument) prints the main help to stdout without host
detection, storage, networking or external utilities. Help gives a purpose
statement, command descriptions, selectors, options, shell setup and examples.
Help renders the fallback major from the script's default-version constant.

For commands other than `exec` and `default`, flags may precede or follow the
selector.
`-t` is accepted only by `available`,
`-d` and `-v` only by `install`, and `-f` only by `env`.
Repeated or unsupported flags, empty selectors, excess arguments and
invalid selector syntax exit 2 before any side effect.

### Exit codes and streams

- `0` success (including empty listings and a `default` query with no default),
  `2` invalid usage, `1` operational failure, no match or ambiguity. `exec`
  returns the child's status instead; a missing command exits 127 and a command
  that cannot run exits 126.
- stdout carries only a command's primary result: listings, the `default`
  query, the `home` path, `env` statements, help and version. Everything
  secondary goes to stderr: progress, confirmations (`Installing <ID>...`,
  `Successfully installed <ID>`, `Already installed <ID>`, `Successfully
  uninstalled <ID>`, `Default JDK set to: <ID>`), diagnostics and ambiguity
  tables. A failed manager operation leaves stdout empty. For `exec`, the
  child's streams pass through unchanged in Bash. PowerShell maps stdout to
  success stream 1 and stderr to error stream 2, including child output, so
  `>`, `2>`, `2>&1`, pipelines and assignment capture work at a PowerShell
  prompt. Expected usage and operational failures, progress, confirmations,
  ambiguity tables and child stderr use native-style stderr records that display
  only the message, without a source location or error header. Only unexpected
  program errors use PowerShell's detailed diagnostic formatting. Informational
  stderr records do not change the command's exit status.
- No match reports `No JDK found matching: <selector>`.
- Multiple matches for `install`, `uninstall`, `default`, `home`, `env` or
  `exec` print `Multiple JDKs match, try again using one of the following
  IDs:` plus the `list` table (one row per ID) on stderr and exit 1.

### Listings

Columns are `ID`, `DISTRIBUTION`, `VERSION` (upstream `java_version`) and `JVM`;
IDs are never truncated. Local listings and ambiguity tables add `DEFAULT`
showing `global`, a major such as `21`, or `global,21`. `available -t` appends a
final `TYPE` column: `ea` for early access, followed by the bracket-stripped
`features` values (`ea,feat,feat2`); a GA row with no features is empty.
Columns are tab-aligned to 8-column stops, sized to the widest value and capped
at four stops; longer values stay untruncated with one separating tab.

### Command behavior

- `available` lists compatible latest JDKs from the shared index across all JVM
  implementations (GA and EA), in upstream order, each ID once. It accepts no
  selector, a major, a distro or a distro-major. An empty result for a valid
  selector exits 1.
- `list [selector]` lists the local directory inventory offline; a selector
  filters it, returning every match without ambiguity errors. With no
  installations it prints `No JDKs are installed. Use 'install' to install one`
  and exits 0. A selector that matches nothing in a nonempty inventory exits 1.
- `install [-d] [-v] [selector]` first resolves range selectors against installed
  JDKs, reporting `Already installed <ID>` when a match exists, using the same
  local selection rules as `home`, `env` and `exec`. Only a genuine local miss
  resolves a remote artifact for a range. Other selectors resolve one remote
  artifact and install it, except for exact local IDs. It is
  idempotent (an existing complete installation reports `Already installed`
  without downloading). A first install initializes a missing default and
  per-major default but never replaces existing ones; `-d` installs and selects
  the global default, even when already installed. `-v` selects the default for
  the resolved JDK's own Java major, replacing an existing selection for that
  major, including when reusing an installation. It is boolean and takes no
  version argument. `-d` and `-v` may be combined as separate flags in either
  order, before or after the selector; duplicate flags are invalid. A failed
  reference update preserves that reference's previous default, though the
  published JDK stays installed. Major selection or initialization runs first,
  then global selection or initialization. The two updates are not a transaction:
  a later failure exits 1 and retains the earlier successful update. With `-v`,
  an unknown Java major fails before either update. Without a
  selector it uses project `java`, user `java`, then major 25.
- `uninstall <selector>` is described under [Uninstallation](#uninstallation).
- `default` prints the current global default ID, or `No JDK currently
  set as the default` (exit 0); `default N` queries major N, reporting `No JDK
  currently set as the default for version N`. An unusable reference is an
  error. Queries are offline and never install. `default set <selector>` sets
  the global default; `default set <major> <selector>` sets that major's default,
  installing when absent. After `set`, one argument is always a selector; two
  are a scope major and selector. Thus `default set 21` sets the global default
  using selector `21`, while `default set 21 21` sets the Java 21 default. A
  scope major is a positive integer without leading zeros; it is not a selector.
  Selectors retain full-ID, major, distro-major, range and exact local directory
  rules. Missing required arguments, empty arguments, invalid scopes and excess
  arguments exit 2 before installation or mutation, with the command grammar
  in the diagnostic. Setters report the selected ID on stderr. Configuration
  never applies to `default`, and `d` uses identical grammar.
- `home` prints one unquoted absolute path. `env` prints shell statements.
  `exec` runs a command. See below.

## Identity and selection

### Full IDs

An ID is `<version>-<distro>` using the index's `version` unchanged. If the
whole leading decimal number of `version` is not the Java major taken from
`java_version`, `<major>-` is prepended (`19-22.3.1+java19-graalvm`,
`8-1.8.0_482-b08-temurin`). `jvm_impl`, OS, architecture and features never
enter the ID. The ID is the installation directory name under `jdks/`.

All Java-major operations derive the major from `java_version`, accepting modern
(`8.0.482+8`) and legacy (`1.8.0_482-b08`) forms; `version` is only the
vendor-version part of the ID. Version strings are never compared or ranked.

### Selector forms

| Form | Meaning |
| --- | --- |
| full ID | Exact match; takes precedence over every other interpretation. |
| `21` | Positive major, no leading zeros. |
| `temurin-21` | Distro plus major; the major is split at the final hyphen, so `graalvm-community-21` works. |
| `21+`, `temurin-21+` | Major 21 or higher. |
| `21..25`, `temurin-21..25` | Inclusive major range. |

Distro tokens are lowercase letters, digits and hyphens starting with a letter.
Bare distro names are not accepted as selectors, except `list` and `available`
where a distro filters, or when the name exactly matches a local directory.
Range bounds are compared as decimal strings; equal bounds are allowed and
reversed or malformed bounds exit 2. Ranges are accepted everywhere except
`uninstall`.

### Local directory inventory

The inventory is the ordinary directories directly beneath `jdks/`, including
hidden and manually named ones. It excludes `default`, numeric names (reserved
for references), files, directory links and unsafe names. A name is a single
component of at most 180 characters, not `.`/`..`, not starting with `-`, and
free of path separators, tabs, CR and LF. Names may contain spaces.

| Directory state | `list` row | Behavior |
| --- | --- | --- |
| Missing/unusable `java` or `javac` | ID + `(invalid JDK)` | Exact-ID uninstall only. |
| Usable launchers, no manifest | ID + `(manifest missing)` | Exact-ID selection and uninstall. |
| Usable launchers, invalid or mismatched manifest | ID + `(manifest invalid)` | Exact-ID selection and uninstall. |
| Usable launchers, valid manifest | Full columns | All selectors work. |

Launchers are executable `bin/java` and `bin/javac` on Unix; on Windows they
may have no suffix or `.exe`, `.bat` or `.cmd`. Diagnostic rows appear only for
`list <ID>`/`uninstall <ID>` and for unfiltered `list`; major, distro and
distro-major filters skip them. Layout is checked, not execution.

### Installed selection (`default set`, `home`, `env`, `exec`)

With an explicit selector:

1. Validate syntax; detect the host; resolve storage. No inventory scan yet.
2. A positive major first checks `jdks/<major>`. A valid reference (managed link
   to a usable installation of that major) selects its target without scanning.
   An existing invalid reference fails and never triggers installation. An
   absent reference continues.
3. An exact directory name `jdks/<ID>` with usable launchers is selected without
   needing a manifest. An invalid layout fails.
4. Otherwise scan the inventory. Exact IDs match first; otherwise only
   directories with a valid manifest and usable launchers participate. A major
   matches every distro; a distro-major matches that distro and major.
5. One match selects it, several are ambiguous (exit 1), and no matches trigger
   installation. Neither the global default nor a distro preference breaks ties.

Selection is offline-first: resolve locally, and only a genuine no-match installs,
using the installation rules (bare major means the configured distro, default
Temurin), then continues with the exact installed ID. Ambiguity, invalid
references and operational failures never install. No remote check is made when
a usable local match exists.

`default` and `default N` read their reference. With an omitted selector
(`_` for `exec`) and no configured selector, `home`/`env` use the stable
`jdks/default` path and `exec` uses its target's physical home. With neither configuration nor a default,
`home`/`env`/`exec` resolve major 25 using the same local-first rules, installing
it if needed.
A dangling or unusable default reports `jvm: default JDK is missing or unusable`
and is never repaired automatically. `default` queries never install.

### Ranges

For commands selecting one JDK, resolution keeps only matches at the highest
matching major and never fails merely because several remain. Locally, that
major's default is used if it selects an eligible candidate; otherwise the
smallest full ID in C-locale order. Missing, dangling or mismatched references
fall back silently without repair. Remotely, the explicit or configured
installation distro is applied, the highest major kept, then the smallest ID in
C order, independent of row order; artifact collisions still fail.
`default set N <selector>` requires the resolved JDK's major to be N. `available` and `list` return
all matches in their usual order. Range `home`/`env`/`exec` use the physical
home. A local match at a lower major wins over remote availability of a higher
one (`home 21+` or `install 21+` with only Java 21 installed uses it offline).
This local-first policy applies to explicit and configured install ranges;
the configured installation distro does not filter local matches. Local
resolution failures never trigger a remote installation. Reused range matches
follow the normal install default initialization and `-d`/`-v` rules.

### Project and user configuration

`.jvmrc` in the current directory (parents are not searched) and
`$XDG_CONFIG_HOME/jvm/config` (default `~/.config/jvm/config`) may contain:

```text
java=21+
distro=graalvm-community
```

`java` is any selector; `distro` is a distribution name. Files are literal
data, never sourced. Blank lines, full-line `#` comments and surrounding
whitespace are allowed; duplicate or unknown keys, empty or invalid values and
unreadable files are errors when a command needs that file. A missing file
leaves its settings unset. Nothing writes configuration.

Each setting resolves independently: command line, then project, then user
file. Files are read only when needed, project file first; every key in a
consulted file is validated, but a malformed lower-priority file is irrelevant
once the project file supplies the needed key.

- `distro` selects the distribution for bare-major and range *installation*
  (then `temurin`). It does not filter local selection. A distro inside a
  configured `java` is retained.
- `install` without selector: `java`, then major 25.
- `home`/`env` without selector, or `exec` with `_`: configured `java`, then
  the global default, then major 25 when both are absent. A configured selector
  that fails does not fall through.
- `available`, `list`, `default` and `uninstall` ignore configuration.

## `home`, `env` and `exec`

`home` prints one absolute path: the stable `jdks/<major>` link for a major
selector backed by a valid reference, the stable `jdks/default` path when there
is no selector, and the physical installation home otherwise (full ID,
distro-major, ranges, or a major without reference). Bash prints POSIX paths
(no `cygpath` conversion).

`env` prints a usage comment, then:

```bash
# Use: eval "$('./jvm' env temurin-21)"
export JAVA_HOME='/absolute/selected/home'
export GRAALVM_HOME='/absolute/selected/home'      # GraalVM manifests only
export PATH='/absolute/selected/home/bin':"$PATH"
```

The comment preserves the script invocation path (`$0` in Bash and the invocation
name or literal command path in PowerShell), quoted for the target shell so the
command can be copied and pasted even when the path contains spaces or
apostrophes. Relative paths remain relative. It preserves the command alias and
argument order as invoked, including `-f` and any explicit selector. Selectors
supplied by configuration or fallback resolution are never added to the comment.
Shell quoting is generated for the argument values, rather than copied verbatim.
PowerShell calls through variables or other expressions
fall back to the resolved script path. Script paths containing CR/LF are rejected. The PATH
line is omitted when the selected `bin` directory is already a whole PATH entry
(literal comparison; no symlink resolution or normalization); `-f` always emits
it. `GRAALVM_HOME` appears when the manifest's `jvm_impl` is `graalvm` and is
emitted regardless of PATH. Values are single-quoted with apostrophes escaped;
paths containing CR/LF are rejected. On Windows Bash, `JAVA_HOME` is a native
forward-slash path and the PATH entry a POSIX path, both via `cygpath`. Output
is prepared fully before printing and never evaluated by `jvm`. `jvm.ps1 env`
emits equivalent PowerShell `$env:` assignments, for example
`iex (& '.\jvm.ps1' env 'temurin-21')`.

`exec` runs `<command>` with `JAVA_HOME` set and the selected JDK's `bin` first
on `PATH` (always prepended). It uses the physical home, never a mutable link,
and does not change the parent shell. Automatic installation initializes missing
defaults using the normal installation rules. The selector is required. A literal
`_` in that position resolves as an omitted selector: project `java`, then user
`java`, then the global default, then major 25. Configuration errors and failed
configured selection do not fall through; an unusable default is an error.
`_` is an `exec`/`x`-only placeholder, outside the shared selector grammar and
configuration values. Other commands give it no placeholder meaning; their
existing exact-directory ID rules still apply. Exec reserves `_` even if an
installation directory has that name.

After consuming the selector, exactly one argument is skipped if it is literally
`--`. The remaining command must be nonempty. The command and every subsequent
argument (including empty strings, flags and literal `--`) are forwarded unchanged;
no later separators or manager flags are parsed. Missing or empty selectors or
commands exit 2 before host detection, storage, networking or installation, with
`jvm: usage: jvm exec <selector> [--] <command> [args...]`. Ordinary explicit
selectors retain their existing validation and bypass configured Java selection.
`exec --help` and `x --help` retain the command-only help exception.

Examples: `jvm x 21 java -version`, `jvm x 21 -- java -version`,
`jvm x temurin-21 javac Example.java`, `jvm x 21+ java Example.java`,
`jvm x _ java -version`, and `jvm x _ -- java -version`.

Bash replaces itself with the child (`exec "$@"`), restoring umask and cleaning
private staging first.

## Installation

### Remote selection

Installation filters the all-release latest index for the host, JDK image type
and supported archive format, plus the explicit or configured distro:

- An exact existing local directory with usable launchers is reused without
  metadata; otherwise an exact ID is matched in the index.
- Ranges reuse a matching installed JDK before consulting configuration for the
  installation distro or fetching metadata; only a local miss uses the remote
  rules below.
- A bare major or range uses the configured distro (default `temurin`);
  explicit distro-major and full IDs keep their meaning. If the distro has no
  match, installation fails without trying another distribution.
- Several distinct IDs fail, listing them; nothing is ranked beyond what ranges
  specify. Windows prefers `zip`, Linux/macOS `tar.gz`, falling back to the
  other format. Exactly one row must remain; duplicates (even identical) fail.
- EA and GA records are both eligible. IDs, checksums and archives are never
  guessed from vendor strings.

### Download and verification

HTTPS with certificate validation is mandatory; HTTP downgrade is never
allowed. A SHA-256 digest from the index is required (`sha256sum`, `shasum -a
256` or `openssl dgst -sha256` in Bash; .NET in PowerShell), compared in
lowercase; the advertised size is checked when present. Mismatches and
incomplete downloads are errors. Artifact timeouts are bounded.

### Extraction and publication

Archives are extracted into a private `jvm/tmp/jdk-<ID>.XXXXXXXX/` staging
directory beside `jdks/` (same filesystem). The tool locates exactly one home
containing `bin/java` and `bin/javac` (including macOS `Contents/Home` and
nested wrappers, found without following links), writes `.jvm-manifest`, and
renames that home directly to `jdks/<ID>`. Archive wrappers and siblings are
discarded. Vendor `release` files are not sourced; when they supply
`OS_ARCH`/`OS_NAME` they are checked against the host. Archive entries named
`.jvm-manifest` are rejected.

Archive validation (Bash) requires tar+gzip or Info-ZIP-compatible `unzip`.
Member names use a conservative alphabet (letters, digits, `. _ + @ % = -` and
`/`); absolute paths, traversal, duplicate normalized paths, special files,
links that leave the home, and links as path ancestors are rejected. Internal
links and hardlinks are preserved. Unrecognized listings fail before
extraction. On Windows, case aliases, reserved device names and trailing dots
are rejected.

Installers use no shared lock; each stages independently. A complete,
compatible `<ID>` that appears during publication wins: the loser discards only
its own copy and reports success. A uniquely marked nested copy left by a lost
`mv` race is renamed back into the private staging directory before deletion;
cleanup never recursively deletes beneath `jdks/`. Existing incomplete or
incompatible ID directories are errors, and complete installations are
immutable. HUP/INT/TERM traps clean owned staging; an uncatchable kill may leave
staging under `jvm/tmp/` outside the inventory. Failed or interrupted
installation preserves existing JDKs and defaults.

### Manifest

`.jvm-manifest` is a non-executable UTF-8 file with exactly three lines:

1. `jvm-manifest-v1`
2. An exact copy of the upstream TSV data row (all fields, escapes, unknown
   trailing columns, and a source CRLF if present; never rebuilt).
3. Local values as a TSV record, currently empty. The empty line is required.

Readers use known column positions, ignore unknown trailing columns, and treat
the local record as append-only. The ID is derived from the saved `version` and
`distro`; platform, URL, format, size, checksum and `java_version` come from the
saved row. Manifests are never sourced or evaluated. Only this format is
recognized; no migration exists.

## Uninstallation

`uninstall <selector>` uses only the offline inventory (no metadata, cache or
network). It accepts a full ID (even without launchers or manifest), a major or
a distro-major; a bare major matches all installed distributions. Ranges are not
accepted. Multiple matches fail with their full IDs; none exits 1. With no
argument it prints `jvm: usage: jvm uninstall <selector>` and `for more
information run: jvm uninstall --help` to stderr and exits 2.

Removal reserves a private directory `jvm/tmp/remove-<ID>.XXXXXXXX` (via
`mktemp -d`), moves `jdks/<ID>` into it with an ordinary `mv`, and only after a
successful move recursively deletes the reservation, reporting `Successfully
uninstalled <ID>`. Nothing beneath `jdks/` is ever deleted recursively. A failed
move reports `couldn't uninstall <ID>` (plus ` (it might be in use)` on Windows)
and exits 1; only an empty reservation is cleaned up after failure, and an
interrupted move or delete may leave data in `jvm/tmp/` for manual cleanup.

References are updated before the move so none intentionally points at a removed
JDK; a failed update aborts the removal and a failed move restores the previous
selection when still safe.

- Global default: replaced from the remaining complete compatible inventory by
  the same major, then the smallest higher major, then the largest lower major;
  ties use C-locale directory-name order. If the removed JDK's major is unknown,
  the first remaining complete compatible ID is used. If none remains the link
  is removed. Directories with unknown metadata are never chosen automatically.
  The result is announced on stderr (`Default JDK set to: <ID>` or `No JDK
  currently set as the default`).
- Major default: replaced by the first remaining usable ID of the same major, or
  removed. A reference never points at another major.
- Only references that actually point at the removed ID are touched.

## Defaults and shell integration

`jdks/default` (global) and `jdks/<major>` (one per installed major) are
directory symlinks on Unix and directory junctions (`mklink /J`) on Windows,
pointing at managed JDK homes beside the installation directories:

```text
jvm/jdks/
  default -> 25.0.1-temurin/
  21      -> 21.0.9-temurin/
  25      -> 25.0.1-temurin/
  21.0.9-temurin/
  25.0.1-temurin/
```

The stable paths let IDEs and tools be configured once (for example
`jvm/jdks/21`) while `jvm` changes the target centrally; tools that cache link
targets may need a refresh. There is no `jvm/default` compatibility link.

Lifecycle:

- A successful first install, including an idempotent one, creates a missing
  global default and a missing major default (the first creator wins under
  concurrency, announcing `Default JDK set to: <ID>` before the install
  message). Later installs preserve existing references unless explicitly
  selecting them with `-d` or `-v`; unrelated data is never replaced. If link
  creation fails, the JDK stays installed and the command exits 1 with an
  explanation.
- `default set <selector>` replaces the global reference; `default set N <selector>`
  replaces major N's reference and requires the selected JDK to be major N.
  Explicit global changes (including `install -d`) leave major references alone
  and vice versa, apart from normal missing-reference initialization during
  installation. `install -v` explicitly selects the resolved JDK's major default;
  `install -d -v` explicitly selects both, major first. Each successful explicit
  selection is announced on stderr (`Java N default JDK set to: <ID>` for a
  major). A mismatch changes nothing.
- Replacement stages a verified link in `jvm/tmp/default.XXXXXXXX`, then swaps
  it with `mv -fT` (GNU) or `mv -fh` (BSD) without following the destination.
  Unrelated files, directories or links outside the managed inventory are never
  replaced. `readlink` inspects references; Unix creation needs `ln`; Windows
  needs `cygpath` and `cmd.exe` with fixed `mklink /J` text, quoted values and
  delayed expansion off. No copy fallback exists. A recovery link preserves the
  old selection if replacement fails or a catchable signal arrives; if
  restoration fails its path is reported. Windows swap atomicity is not
  established, and an uncatchable kill during it may need manual recovery from
  `jvm/tmp/default.XXXXXXXX/previous`. Concurrent explicit changes: last
  publication wins.

Shell setup is manual; the tool never edits profiles or the registry. Unix:

```bash
export JAVA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/jvm/jdks/default"
export PATH="$JAVA_HOME/bin:$PATH"
```

Windows Bash:

```bash
export JAVA_HOME="$(cygpath -m "${XDG_DATA_HOME:-$HOME/.local/share}/jvm/jdks/default")"
export PATH="$(cygpath -u "${JAVA_HOME}")/bin:$PATH"
```

An executable cannot export variables into its parent shell; an existing
`JAVA_HOME`, earlier PATH entries, command caching or software that resolves
`JAVA_HOME` once can prevent immediate adoption and may need a refreshed shell.

## Host compatibility

- Detect OS, architecture and Linux libc. API values: `macosx`, `linux`,
  `linux-musl`, `windows`; `x86_64`, `aarch64`. Cygwin, MSYS2 and Git Bash
  target Windows JDKs; WSL targets Linux. glibc and musl are distinguished, a
  glibc-only JDK is never installed on musl, and undeterminable compatibility
  fails clearly. Emulated architectures are not chosen silently.
- JDK images only; `.tar.gz` and `.zip` only. Other installers are omitted.
- Unsupported host combinations fail with the detected platform.

## Storage

XDG conventions apply on every platform, including Windows and macOS. Only
absolute, nonempty overrides are honored (otherwise the fallback is used); a
missing usable `HOME` is an error, and the working directory is never an
implicit home. Windows Bash accepts absolute drive paths converted to POSIX
form.

| Purpose | Location |
| --- | --- |
| Installations | `${XDG_DATA_HOME:-$HOME/.local/share}/jvm/jdks/<id>/` |
| References | `.../jvm/jdks/default`, `.../jvm/jdks/<major>` |
| Private staging | `.../jvm/tmp/` (`jdk-<id>.*`, `remove-<id>.*`, `default.*`) |
| Configuration | `${XDG_CONFIG_HOME:-$HOME/.config}/jvm/config` |
| Metadata cache | `${XDG_CACHE_HOME:-$HOME/.cache}/jvm/` |

Clearing the cache never removes installations or the default. Paths with
spaces and shell metacharacters are handled everywhere; nothing is passed to
`eval` or sourced (manifests, API data, configuration, `release` files).

## Metadata index

The runtime base is `https://getjvm.dev/index`, which redirects over HTTPS to
`jbangdev.github.io/jdkdb-index` (redirects are followed). Discovery and
installation share one file per platform:

```text
/metadata/all/{os}/{arch}/jdk-latest.tsv
```

It lists the latest release per major for each distro and JVM implementation,
including EA rows the API returns (GA is preferred within a group). The
[OpenAPI definition](https://jbangdev.github.io/jdkdb-index/openapi.yaml)
documents the static files. No history index is fetched.

The TSV is UTF-8 with a header and these 15 columns, in order: `release_type`,
`os`, `architecture`, `image_type`, `jvm_impl`, `vendor`, `distro`,
`java_version`, `version`, `file_type`, `url`, `filename`, `size`, `sha256`,
`features`. The provider only appends columns at the end and populates every
field. Usage: `os`/`architecture`/`image_type` filter for the host and JDKs,
`jvm_impl` is display and GraalVM detection only, `distro`/`version`/
`java_version` build IDs and major matching, `file_type` selects the archive
format, `url`/`filename`/`size`/`sha256` drive installation, and `features`
supplies the `TYPE` display and a `musl` host check (not identity).

Discovery trusts the index: it does not validate headers, column counts,
populated fields, checksums, URLs or feature syntax, either fetched or cached,
skips only the header row, and prints each ID once (first row wins, with its
display fields) without comparing builds. Backslash escapes (`\\`, `\t`, `\r`,
`\n`) in unused text are left alone; literal tabs are field boundaries and CRLF
endings are stripped. Upstream errors are fixed upstream. Installation (not
discovery) requires a unique row after the archive-format preference.

### Cache

Each index lives under the cache directory keyed by exact URL (one
`all-<os>-<arch>-jdk-latest-v1` entry per platform), with URL, ETag,
Last-Modified and last-check metadata.

- A valid cache (matching URL/time metadata, nonempty body) younger than one
  hour (3600 s) is used without network access.
- Otherwise a conditional GET is sent: `If-None-Match` with the ETag preserved
  verbatim (including a weak `W/` prefix), or `If-Modified-Since` when only
  Last-Modified exists; validators are opaque. `304` reuses the cache and
  updates the check time; a `304` without a usable body is retried
  unconditionally. A nonempty `200` is published atomically (temporary file,
  then rename) with its validators and is not content-validated.
- Failed transfers and empty bodies never overwrite the cache. If a refresh
  fails and a valid cache exists it is used silently, without a warning. With no
  cache, a failed fetch is an actionable error, never an empty listing.
- Downloaders are detected, not assumed: Bash supports `curl` and `wget`
  (including non-GNU wget), falling back to an unconditional GET when
  conditional requests are unsupported. Curl uses 45 s (metadata) and 30 min
  (artifact) limits; wget a 15 s connect/read timeout with one attempt.
  PowerShell uses `HttpWebRequest` with equivalent behavior.

## Implementation constraints

- **Bash `jvm`**: one file, executable and runnable as `bash ./jvm`; LF line
  endings and a Bash shebang. Supports Bash 3.2 and later on Linux and macOS
  (no associative arrays or newer features). Windows support targets current
  Cygwin, MSYS2 and Git Bash versions; Bash 3.2 on Windows is outside the
  supported scope and is not built or tested. Uses
  Bash plus ordinary utilities and no Python, Perl, Ruby, Node.js or `jq`;
  no general JSON parser exists. GNU-only behavior is not assumed (`readlink
  -f`, `sort -V`, `stat`, `sed -i`, `mv -T`); capabilities are detected and
  missing ones give an actionable error. Required capabilities per command:
  `curl` or `wget`; `tar` with gzip for `.tar.gz`; `unzip` for `.zip`; a SHA-256
  tool; `cygpath` on Windows. `--help` and local commands need no network or
  archive tools when a usable local match exists. No runtime dependencies are
  installed automatically; no installers or vendor-provided commands are run; no telemetry; user-owned locations only.
- **PowerShell `jvm.ps1`**: a separate Windows-only entry point for Windows
  PowerShell 5.1 using built-in .NET only (no Bash, PowerShell Core features or
  packages). It follows the same selectors, configuration, storage layout, cache
  lifetime, manifest, defaults and offline-first policy. Paths are native
  Windows paths and directory junctions provide references. The two
  implementations MUST behave alike wherever the platform allows; any
  difference is a documented boundary below, and a behavior change applies to
  both in one change.
- **`jvm.cmd`**: a thin launcher for `cmd.exe` and double-click use. It runs
  the `jvm.ps1` beside it with `powershell.exe -NoProfile -ExecutionPolicy
  Bypass -File`, forwards all arguments and returns its exit code. It contains
  no parsing logic.
- Fixtures, tests and contributor tooling stay outside the shipped scripts and
  are never runtime dependencies. No runtime dependency on Java.

### PowerShell boundaries

- PowerShell can consume an unquoted `--` at a prompt. Separator-free exec
  invocation and a literal optional separator both work with the argument vector
  received by the script. A literal `--` intended for the child must be quoted.
- The `_` placeholder works through `-File` and `jvm.cmd`. Windows PowerShell
  5.1 rejects a standalone `-` among child arguments to `-File` before script
  entry; direct script invocation at a PowerShell prompt accepts that argument.
- `exec` starts `.exe`/`.com` directly. `.bat`/`.cmd` run through `cmd.exe`,
  which re-parses their arguments as it would without `jvm`. `.ps1` scripts run
  with `powershell.exe -NoProfile -NonInteractive -File` (Windows PowerShell
  5.1 from the system directory when the host has no `powershell.exe`), subject
  to the execution policy. An extensionless command, bare or path-qualified,
  prefers `.ps1` over the `PATHEXT` extensions, as PowerShell does.
- `exec` forwards child output as text lines through PowerShell streams. Output
  without a newline is delivered when the line completes or the child exits;
  this is not a byte-preserving or terminal-attached output path.
- ZIP extraction uses .NET and rejects symbolic links. `tar.gz` needs the
  Windows `tar.exe` and rejects links and special entries. Both are stricter
  than Bash, which preserves verified internal links.

## Open items

- **Roadmap idea: installer for the `jvm` tool.** Provide a hosted bootstrap
  installer for Bash and Windows PowerShell, plus an invocation from CMD.
  Proposed commands (endpoints are not yet provided or verified):

  ```bash
  curl -fsSL https://getjvm.dev/sh | bash
  ```

  ```powershell
  iex (irm 'https://getjvm.dev/ps1')
  ```

  CMD could invoke the PowerShell installer through Windows PowerShell:

  ```cmd
  powershell.exe -NoProfile -Command "iex (irm 'https://getjvm.dev/ps1')"
  ```

  These examples use the project's existing `getjvm.dev` domain. The installer
  would install the tool itself, distinct from `jvm install` downloading a JDK.
  Investigate project-local versus user-wide placement, PATH setup and the
  existing manual shell-setup policy, installing `jvm.ps1` together with
  `jvm.cmd` on Windows, release/version selection, updates and removal, and
  download verification and interrupted-install recovery. Validate quoting and
  bootstrap behavior on supported shells, including Windows PowerShell 5.1 and
  CMD. This is a roadmap proposal, not an available installer or a change to
  current installation and shell-setup behavior.
- **Roadmap investigation: minimum-major selectors by default.** Consider
  changing `25` from exactly major 25 to major 25 or higher (currently `25+`),
  with `25!` expressing exactly major 25. The motivation is that a requested
  Java major more often means a minimum requirement than an exact requirement.
  Backward compatibility is not a goal. This is an investigation idea, not an
  adopted selector change; the selector rules above remain current behavior.
  Investigate parsing ambiguity and whether the overall syntax becomes worse:
  distro-qualified forms such as `temurin-25!` and `temurin-25`, bounded ranges,
  full-ID precedence and manually named directories, and the fate of `25+`.
  Assess `!` quoting and argument handling in supported shells and launchers
  (including interactive Bash history expansion and cmd.exe delayed expansion),
  configuration and generated `env` usage comments. Evaluate effects on
  per-major references, fallback selection, local-first range resolution,
  `default set N <selector>`, and `uninstall`'s exclusion of ranges. Compare
  representative command and configuration examples for clarity and convenience before
  deciding whether to adopt the change in both implementations.
- **TODO:** extend `tests/powershell.ps1` with offline coverage of the
  PowerShell network and archive paths: a local `HttpListener` server, index
  fetching and 304/cache handling, ZIP and `tar.gz` installation, checksum
  mismatch, traversal and link rejection, HTTP failures. These paths are
  currently unverified.
- Junction replacement and interruption on native Cygwin/MSYS2, macOS
  replacement, real-JDK runs beyond native Git Bash and broader PowerShell
  platform coverage remain unverified; see tests/README.md.
