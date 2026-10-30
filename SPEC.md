# jvm specification

## Status and purpose

`jvm` is a small command line tool for obtaining and selecting Java Development
Kits (JDKs). Projects commit a copy of the tool and invoke it directly; users do
not need to install a separate JDK manager. JDK downloads and user preferences
are shared across those project copies.

This document distinguishes implemented discovery, installation, offline
listing, uninstallation and persistent defaults from later milestones. Requirements expressed as MUST
are mandatory for their stated scope. Details marked **proposed** remain design
choices for review.

### First implementation milestone (authorized 2026-10-29)

Implemented in the single Bash file `jvm`: `help`, `--help`, `--version`, and
`available [selector]`; host and libc detection; validated XDG cache paths;
GA latest TSV fetching through curl or wget; discovery across JVM implementations;
trusted TSV reading; compatible archive filtering; ID construction and selector
filtering; and a one-hour metadata cache with conditional requests and silent fallback.
That milestone shipped version 0.1.0. Discovery listings preserve upstream order
and return all matching IDs; discovery does not choose the highest version or
an artifact for installation. Each matching ID displays once. Duplicate IDs are collapsed
silently; build conflicts are not inspected. The project owns the index and fixes
index problems upstream. Discovery trusts its contents and prioritizes speed.
`available` accepts a Java major, a distro, or a distro-major selector. Exact-ID
selection has been removed from discovery. Every selector uses the same latest
index; distro-major does not fetch historical versions. `available --help` shows
the main help without detecting the host, accessing storage, or networking.
A header-only index is a successful empty inventory; a selector with no match
exits 1. Unknown commands and excess/empty arguments exit 2.

Adopted implementation choices explicitly authorized by the user: Bash 3.2 as
the baseline, the command names below, exit codes 0/2/1, and a one-hour freshness
interval. The four discovery entry points remain supported. The
installation and offline-listing extension is described below. Persistent defaults
and manual shell setup were subsequently authorized on 2026-10-30. Session
switching, command execution and general JSON parsing remain deferred.
Help advertises implemented commands.

### Installation and offline listing (authorized 2026-10-30)

Version 0.2.0 adds `install <selector>` and `list`. Installation
uses the same GA latest index and cache as discovery, filtering compatible JDKs
and zip/tar.gz before selection. It requires SHA-256, checks advertised size,
validates archive paths and links before extraction, checks the JDK layout and
publishes a complete installation by rename on the destination filesystem.
Local listing uses only durable managed manifests and checks the recorded host
and JDK layout. Empty inventory succeeds. The user restored `list [selector]`
on 2026-10-30, superseding the earlier removal of its optional selector.
This milestone originally left defaults unchanged; the persistent-default
extension below supersedes that behavior. No command edits shell profiles.

Exact full IDs take precedence for installation selectors. Otherwise
accept a positive major or distro-major (including hyphenated distros). A bare
install major uses Temurin: `install 22` is equivalent to `install temurin-22`.
This distribution is currently hard-coded. `list`
returns the complete managed inventory unless a selector filters it. `install` filters the latest index and
requires one matching ID; multiple IDs fail with their full IDs as choices.
Versions are never sorted or ranked, and vendor labels do not need parsing.
This 2026-10-30 user clarification supersedes the earlier highest-version rule.

For the resolved ID, Windows prefers zip and Linux/macOS prefer tar.gz, falling
back to the other supported format. Exactly one row must remain in the chosen
format; even identical duplicate rows fail. No feature/JVM/build preference or
ID extension resolves collisions. An already complete compatible ID succeeds
without another artifact download; an exact installed ID also works offline.

### Uninstallation (authorized 2026-10-30)

`uninstall <selector>` resolves exclusively against the complete managed offline
inventory used by `list`. It accepts an exact full ID, positive major, or
distro-major, including hyphenated distros and legacy versions. A bare major
matches all locally installed distributions; it does not assume Temurin.
This user clarification on 2026-10-30 applies only to uninstall; install keeps
its Temurin default. Exact IDs take precedence. Multiple matching IDs fail with all their
full IDs and ask the user to retry using one; no match exits 1. Invalid usage
exits 2. No metadata fetch or cache access is needed.

Reserve a private directory using `mktemp -d` at
`jvm/tmp/remove-<ID>.XXXXXXXX`, alongside `jdks/` on the data filesystem. First
use ordinary `mv` to move `jdks/<ID>` into that directory. Only after a successful
move recursively delete the private directory and report
`Successfully uninstalled <ID>`. Never recursively delete beneath `jdks/`.
A failed move reports `couldn't uninstall <ID>` on stderr, adding exactly
` (it might be in use)` on Windows, and exits 1. Only an empty reservation is
removed after failure; a failed or interrupted move/deletion may leave temporary
data for manual cleanup. Default replacement now follows the extension below;
shell configuration is never edited. Concurrent installations use independent
staging directories and no lock.

See [tests/README.md](tests/README.md) for exact verification commands and gaps.

## Scope

The complete version MUST:

- List JDKs available for download from jdkdb-index.
- Download and install compatible JDKs into user-owned storage.
- List JDKs installed by this tool, including their full IDs and default status.
- Select a persistent default JDK for the user.
- Accept a full JDK ID, a Java major version, or `<distro_name>-<major_version>`
  wherever an installed JDK is selected.
- Stay compact enough to copy into every Java project.
- Keep help and routine output short and to the point. Show extra technical
  information only when it is important to the user's immediate task; keep
  storage, dependency, cache and contributor details in documentation.
- Continue useful work when nonessential inconsistencies can be handled safely.
  A technical detail affecting one candidate MUST NOT abort an otherwise usable
  discovery listing. Report important limitations briefly, preserve valid results,
  and reserve failures for cases where the requested operation cannot complete
  safely (for example, no usable metadata or no selector match).

Future work, which MUST NOT be implemented in the initial version:

- Select a JDK for the current shell session, potentially using dynamic shims
  and a shell integration protocol.
- Run an arbitrary command with a selected JDK.

Initial scope does not require system-wide installation, automatic
updates, importing unrelated installations, project version files, or a GUI.
Discovering arbitrary JDKs on PATH or in vendor-specific directories is separate
from listing installations managed by `jvm`.

## Implementation and portability constraints

- The distributed tool MUST be one Bash file named `jvm`, directly executable
  where supported and runnable as `bash ./jvm` everywhere supported.
- It MUST run on Linux, macOS, and Windows through Cygwin, MSYS2, and Git Bash.
  Windows support means this Bash execution environment; a native PowerShell or
  cmd.exe implementation is not required.
- **Adopted:** support Bash 3.2 and later, including macOS's bundled Bash. Avoid
  associative arrays and other features requiring newer Bash.
- All runtime logic MUST be Bash, apart from ordinary system utilities. Do not
  require Python, Perl, Ruby, JavaScript, Node.js, `jq`, package managers,
  downloaded helper executables, or a separate native launcher.
- Java is the only permitted additional programming language. A Java feature
  MUST document why a suitable existing JDK is assured, or how Bash first
  installs a specifically known suitable JDK without invoking Java. No circular
  dependency on Java for initial discovery, metadata parsing, or installation.
- Development tools and test fixtures need not be shipped with the single file.
  They MUST NOT become hidden runtime dependencies.
- Prefer clarity and small dependencies to code golfing. **Proposed:** record
  script byte size as it grows; there is no arbitrary hard size limit yet.

### System utilities

Use Bash builtins and widely available filesystem/text utilities. Detect actual
capabilities and accommodate GNU/BSD differences; do not assume GNU `readlink
-f`, `sort -V`, `date`, `stat`, `sed -i`, or `mv -T` behavior.

| Capability | Required approach |
| --- | --- |
| HTTPS transfer | Support both `curl` and `wget`; use whichever is available. |
| Filesystem/text work | Ordinary tools such as `mkdir`, `mv`, `rm`, `ln`, `uname`, `mktemp`, `sed`, `awk`, and `sort`, only as needed. |
| Extraction | `tar` with gzip for `.tar.gz`; `unzip`, or a verified ZIP-capable `tar`, for `.zip`. |
| Strong checksum | Detect a compatible implementation, such as `sha256sum`, `shasum -a 256`, or `openssl dgst -sha256`. |
| Windows path conversion | Use `cygpath` when supplied by the Bash environment and conversion is needed. |

An individual utility is not assumed to exist on every platform. Check only the
capabilities a command needs and give an actionable error when unavailable.
`help` and local listing MUST NOT require networking or archive tools. Do not
install missing dependencies automatically. Other archive formats and native
installers are outside initial scope.

## Adopted command interface

The names and exit codes are adopted. `help`, `--help`, `--version`,
`available`, `list`, `install`, `uninstall`, and `default` are implemented.
The following commands describe the intended complete interface.

```text
jvm help
jvm --help
jvm --version
jvm available [selector]
jvm list [selector]
jvm install <selector>
jvm uninstall <selector>
jvm default [selector]
```

- `available` lists compatible JDKs across JVM implementations from the API's
  latest index, covering the latest release of every major across distributions. No argument,
  a major, a distro, and a distro-major all use that same index and cache.
  Historical versions are outside the current discovery interface.
- `list [selector]` lists complete managed installations offline. With no
  selector it returns the complete inventory. If no complete managed JDKs are
  installed, print `No JDKs are installed. Use 'install' to install one` to stdout,
  without a table header, and exit 0 whether or not a valid selector was supplied.
  An optional full ID, major, distro or distro-major filters this inventory.
  Exact IDs take precedence; majors match all distributions. Return every
  matching ID without ambiguity errors. With a nonempty installed inventory,
  a selector with no match exits 1;
  invalid syntax or excess/empty arguments exit 2. No network or cache access
  is allowed.
- `install` resolves a remote selector and installs that exact artifact. It is
  idempotent for an already complete installation. It initializes a missing
  default, but MUST NOT replace an existing default.
  Print `Installing <ID>...` to stderr after resolving the full ID and before
  downloading the artifact, then
  `Successfully installed <ID>` to stdout after publication. An existing complete
  installation reports `Already installed <ID>` without another download.
  With no argument, print exactly two lines on stderr:
  `jvm: usage: jvm install <selector>` followed by
  `for more information run: jvm install --help`. Exit 2.
  `install --help` prints the main help page to stdout with exit 0 and no stderr.
  Both forms need no external utilities and perform no host detection, storage
  access or networking. This supersedes the earlier install-specific help.
  `-help` is invalid and exits 2, like other invalid selectors.
- `uninstall` removes one complete managed installation using the offline
  selection and move-before-delete procedure above.
  With no argument, print `jvm: usage: jvm uninstall <selector>` followed by
  `for more information run: jvm uninstall --help` on stderr and exit 2,
  without host detection, storage access, networking or external utilities.
- `default` without an argument reports the current selection, or explicitly
  reports that none exists. With an argument it selects an already installed
  JDK; it MUST NOT silently download one.
- `help` shows implemented command usage and a short selector explanation.
  Include a brief purpose statement, one-line command descriptions and a few
  examples. Keep it readable without a wall of text; omit routine implementation
  details and deferred commands. This clarifies the user's 2026-10-30 request
  that help should explain the tool rather than compress usage into a few lines.
- Full IDs MUST be shown untruncated. Discovery does not accept them as selectors;
  exact IDs are accepted by installation, uninstallation and local listing. Listings
  show `ID`, `DISTRIBUTION`, `VERSION`, and `JVM`. Omit the platform column;
  discovery already filters for the current host.
  Local listings and local ambiguity tables add a `DEFAULT` column marked `*`
  when a managed default reference exists. IDs themselves remain unchanged.
- Align listing headers and values with tabs at 8-column stops. Size each column
  from the widest displayed value or header, placing the next column at the
  following tab stop, capped at four tab stops (32 columns) per column. Longer
  values remain untruncated and get one separating tab; they may overflow the
  usual alignment without widening the other rows. Preserve row order and apply
  the same layout to redirected output; repeated tabs are display padding.
- Diagnostics and progress go to stderr; command results go to stdout. Avoid
  interactive prompts and terminal-only formatting in redirected output.
- When install, uninstall or default matches multiple IDs, print
  `Multiple JDKs match, try again using one of the following IDs:` followed by
  the matching JDKs using the same table renderer as `list <selector>` (ID,
  distribution, version and JVM, with the same headers and tab alignment).
  Print each ID once, using its first matching row. The message and table go to
  stderr; stdout stays empty and the command exits 1. Uninstall shows the local
  matches; install shows its matching remote candidates, including its default
  distribution filter for bare majors.
- **Adopted:** exit 0 for success (including empty lists and no default), 2 for
  invalid usage, and 1 for operational failures, no selector match, or ambiguity.
  A selector with no matching JDK reports `No JDK found matching: <selector>`.

## Identity and selection

### Full IDs

A full ID MUST use `<version>-<distro>` for every JVM implementation. Use the API's
`version` value as supplied for IDs, displayed versions, and major matching;
`java_version` is not used. This adopts the user's manual change, confirmed
on 2026-10-30, and supersedes the earlier Java-version-based identity decision.
`distro` is the canonical distribution identifier. Never append `jvm_impl` to
the ID. This 2026-10-30 user decision prioritizes shorter IDs; collisions across
JVM implementations fail installation if multiple rows remain after archive
preference; discovery still silently deduplicates. For example:

```text
21.0.12+8-temurin
21.0.12+8-semeru
```

The ID MUST also be the on-disk installation folder name, directly beneath
`jdks/`. For example, `21.0.12+8-temurin` is installed in
`${XDG_DATA_HOME:-$HOME/.local/share}/jvm/jdks/21.0.12+8-temurin/`.
Validate IDs as single portable directory names before using them in paths;
reject path separators, traversal components, and names invalid on supported
filesystems. Do not silently rename a folder or use a separate opaque key.

IDs are scoped to the current machine's compatible JDK inventory. OS,
architecture, archive variant and JVM implementation MUST NOT appear in the ID.
Ignore features for identity and user selectors. Filter metadata for the host and
supported archive format before displaying IDs. Multiple archive records for the
same JDK do not represent separate installations. Discovery trusts the index,
prints each ID once, and does not inspect or warn about different builds sharing
an ID, including when JVM implementations differ. The first matching row
supplies display fields (including the JVM column); no artifact is selected.
Installation applies the format preference and unique-row requirement above;
discovery does not perform those checks.

Installed manifests preserve the ID even if the corresponding download later
disappears from the upstream index. Retain platform and source artifact metadata
for validation, without encoding them into the ID.

### Discovery selectors (implemented)

- With no selector, list compatible latest JDKs across distributions, majors and
  JVM implementations.
- A positive integer such as `21` filters by the major extracted from `version`.
- A canonical distro such as `temurin` filters by distribution across majors.
  Hyphenated distro names such as `graalvm-community` are supported.
- `<distro>-<major>` such as `temurin-21` filters by both. Split a positive major
  suffix from the final hyphen; other hyphens remain part of the distro name.
- All forms use `/metadata/ga/{os}/{arch}/jdk-latest.tsv`. The user withdrew the
  proposed separate history endpoint for distro-major; do not fetch history or
  add JVM-specific requests for this selector.
- Include all `jvm_impl` values in the broad index for every selector. Do not
  filter to HotSpot or select a preferred JVM. The 2026-10-30 clarification
  supersedes HotSpot-only discovery: HotSpot was only intended as a parameter
  for the separate endpoint that was subsequently withdrawn. JVM implementations
  remain eligible, but shared version-distro IDs collapse silently; no suffix or
  collision-resolution policy is introduced.
- Exact-ID matching is removed from `available`. Invalid selector syntax exits 2;
  a syntactically valid selector with no compatible matches exits 1. Majors must
  be positive decimal integers without leading zeros. Distro tokens use lowercase
  letters, digits and hyphens, starting with a letter. Inputs are validated before
  transfer or storage use. Positive numeric suffixes without leading zeros use
  the distro-major interpretation.
- `jvm available --help` prints the same short help as `jvm --help`, with exit 0.

### Installation selectors (implemented)

- Try an exact full-ID match first.
- A positive integer such as `21` selects that major from the hard-coded
  default distribution, `temurin`: `install 21` means `install temurin-21`.
  This applies only to installation; `available 21` still lists all distros.
- A selector such as `temurin-21` selects that distribution and Java major.
  Split the major from the final hyphen; distro names can contain hyphens.
- Distribution names use canonical jdkdb-index identifiers.
- `list` is an optionally filtered offline inventory. `install` and
  `default` must resolve to a single artifact or installation.
- Filter the latest index by the major extracted from upstream `version` and
  the explicit or default distro. The endpoint already selects latest releases; do not
  rank versions or reject vendor version syntax such as `+java17` or `-Final`.
- If several distinct IDs remain, fail with their full IDs and ask the user
  to supply a full ID. Beyond the explicit/default distro filter, do not prefer
  a vendor, JVM, build or API row order. If Temurin has no compatible match,
  fail rather than falling back to a different distribution.
  A single ID proceeds to archive-format preference and the unique-row check.
- Print the resolved ID on installation
  and selection. A persistent default stores the exact ID, not the selector.

Remote resolution uses the API's own latest selection for each major version;
the API need not supply an ordering key. Resolve within that inventory, retaining
the ambiguity rules above. Local default resolution works offline and bare majors
match every installed distribution. Current `list` returns all local selector
matches rather than resolving a single installation.

**Future requirement (user requested 2026-10-30):** make the default installation
distribution configurable in a config file. The current implementation always
uses `temurin`; it does not read configuration yet. The file format and exact
filename remain undecided, within the XDG configuration location described below.

## Host compatibility

- Detect the target OS, process architecture, and Linux libc family. Normalize
  names to API values, for example macOS to `macosx`, AMD64 to `x86_64`, and ARM64
  to `aarch64`. Cygwin/MSYS2/Git Bash target Windows JDKs; WSL targets Linux.
- Distinguish glibc and musl; never knowingly install a glibc-only JDK on musl.
  Fail clearly when compatibility cannot be determined.
- Select JDK images, never JRE-only images. Discovery selects GA across all JVMs.
  EA selection requires a later explicit interface decision.
- Choose compatible `.tar.gz` or `.zip` artifacts. Unsupported installers may
  be omitted from the discovery listing; document these filters here.
- Do not silently choose an emulated architecture. Unsupported host combinations
  must fail with the detected platform and useful context.
- Normalize the JDK home after extraction, including macOS `Contents/Home`.
  Publish the actual home directly as `jdks/<ID>/`, with no `payload`, archive
  root or `Contents/Home` wrapper. Locate exactly one home containing `bin/java`
  and `bin/javac`; Unix launchers must be executable files. Windows accepts
  launchers with no suffix or `.exe`, `.bat`, or `.cmd`. Use ordinary `find`
  without following directory links to locate homes, including nested archive
  wrappers. Validate version/platform metadata without sourcing vendor files.
  The installed manifest retains the index's upstream version and host tokens.
  When a vendor `release` file supplies OS_ARCH/OS_NAME, installation checks
  them against the host without executing the file. JAVA_VERSION is not used
  for identity or selection: it can differ from the upstream vendor version.

## User storage

Use the freedesktop XDG directory conventions on every platform, including
Windows; do not substitute AppData or macOS Library paths.

| Purpose | Location |
| --- | --- |
| Installed JDKs and their manifests | `${XDG_DATA_HOME:-$HOME/.local/share}/jvm/jdks/<id>/` |
| Private installation staging | `${XDG_DATA_HOME:-$HOME/.local/share}/jvm/tmp/jdk-<id>.XXXXXXXX/` |
| Private removal staging | `${XDG_DATA_HOME:-$HOME/.local/share}/jvm/tmp/remove-<id>.XXXXXXXX/` |
| Persistent default reference | `${XDG_DATA_HOME:-$HOME/.local/share}/jvm/default` |
| User configuration, if needed | `${XDG_CONFIG_HOME:-$HOME/.config}/jvm/` |
| Download and metadata cache | `${XDG_CACHE_HOME:-$HOME/.cache}/jvm/` |
| Operational state, if needed | `${XDG_STATE_HOME:-$HOME/.local/state}/jvm/` |

Only absolute nonempty XDG overrides are valid; ignore relative values and use
the fallback. In Windows Bash environments, accept absolute drive paths after
conversion to the environment's POSIX path representation. Missing usable HOME
and required overrides must yield a clear error. Never create an empty PATH
component or use the working directory as an implicit home.

Store installation metadata sufficient for offline listing and selection: ID,
distribution, Java version, platform/libc, JVM implementation, JDK home,
source URL, and expected/verified digest. Use a versioned, non-executable data
format. Cache deletion must not remove installations or reset the default.

**Implemented manifest v2:** `.jvm-manifest` is one UTF-8 TSV record, never
executable or sourced. Its fields are `jvm-install-v2`, ID, distro, upstream
version, JVM implementation, OS (including libc), architecture, relative JDK
home, artifact URL, verified lowercase SHA-256, archive format, advertised size
(empty if absent). The relative home is `.`: `<ID>` itself contains `bin`,
`lib`, vendor metadata and any hidden home files. Extract to private staging,
locate and validate the actual home, write its manifest, then rename that home
directly to `<ID>` on the same filesystem. Discard archive wrappers and siblings
with the operation's remaining staging files. Reject archive-provided
`.jvm-manifest` entries in the selected home and links that would escape the
selected home after normalization. Local listing
requires a matching ID/platform, recognized manifest and usable java/javac
layout; it ignores incomplete, incompatible or unmanaged directories.

During preproduction, backward compatibility with earlier storage layouts and
manifest formats is not required. Only the current flat layout and manifest
format are recognized; no compatibility reader or migration is provided.

Installers use no shared-storage lock. Each independently stages in a unique
`tmp/jdk-<ID>.XXXXXXXX/` directory created by `mktemp`, alongside `jdks/` on the
data filesystem. Temporary directories never enter the inventory directory.
The complete, validated home
and manifest are given that same unique basename inside staging. Check for a
complete winner immediately before moving that home to `jdks/<ID>`.

If the destination appears during the move, ordinary `mv` may put the uniquely
named home inside the winner's directory as `<ID>/jdk-<ID>.<random>`. Cleanup
first renames that owned copy back to its now-empty location inside the private
staging directory, then deletes it there. Never recursively delete the copy
while it remains beneath the winner. A uniquely named marker identifies the
copy owned by this operation; cleanup never removes an unrelated directory.
Different installers reclaim into their own distinct temporary paths. Remove the marker
from a successfully published home as well. No GNU-only `mv` option is needed.

If another installer publishes a complete compatible installation of the same
ID before or during the move, discard only this installer's copy and print the
normal `Successfully installed <ID>` message. Concurrent installers may download
and extract the same artifact independently; no waiting or stale-lock recovery
is needed. A publication failure without a complete winner remains an error.
Traps clean up owned staging and marked copies on HUP/INT/TERM. An uncatchable
kill can leave staging or a marked nested copy; neither appears as an installation
or blocks new installers. Existing incomplete or incompatible ID directories cause an error
instead of replacement. Complete installation directories are immutable.

Archive inspection requires tar gzip listing/extraction or Info-ZIP-compatible
`unzip -Z -1`, `-Z -l`, `-p` and extraction. This implementation does not yet
provide a ZIP-capable tar fallback. Tar verbose listings must expose ordinary
file/directory entries, `name -> target` symlinks and `name link to target`
hardlinks. Ambiguous or unrecognized listings fail before extraction. Archive
member names use a conservative ASCII alphabet (letters, digits, `. _ + @ % = -`
and `/`, without the spaces in this description); absolute paths, traversal,
duplicate normalized paths and special files are rejected. Links must remain
internal; links as ancestors of entries or link targets are rejected. Internal
file-link chains and hardlinks to regular members are preserved. Unsupported
pathname/listing forms fail safely rather than being guessed. On Windows,
case aliases, reserved device names and trailing dots are rejected. These
restrictions concern archive member names; HOME and XDG paths support spaces.

Selection keeps upstream version strings intact. For example,
`22.3.3+java17-graalvm` and `22.1.0.1-Final-gluon-graalvm` both match major 22.
Their vendor annotations are neither errors nor a reason to prefer one ID.
Bare `install 22` filters to Temurin; explicit distro-major/full-ID selectors
remain available for these other distributions.
Installation has no version comparator, recognized-version grammar or numeric
component limit. Existing portable ID/path checks still apply before storage.

## Persistent default and shell integration

**Authorized and implemented 2026-10-30:** `default` references the selected
normalized JDK home, using a directory symlink on Unix and `mklink /J` directory
junction on Windows. Users add its `bin` directory to PATH once. The main help
has a dedicated `Shell setup` section with Unix and Windows Bash instructions.
Default selection prints no setup instructions. Windows setup converts JAVA_HOME
to a Bash POSIX path before adding its bin to PATH, then to a native drive path
with forward slashes for native tools. This avoids a drive colon in PATH.
The Unix setup is:

```bash
export JAVA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/jvm/default"
export PATH="$JAVA_HOME/bin:$PATH"
```

Use the same converted path and XDG validation rules as storage handling.
Do not automatically edit shell profiles or the Windows registry. Selection is
persistent through the reference; subsequent program invocations resolve it.
An executable cannot export variables into its parent shell. An existing
JAVA_HOME pointing elsewhere, earlier PATH entries, command caching, or software
that resolves JAVA_HOME once can prevent immediate adoption; describe how to
refresh the shell environment or restart that software.

`default` without a selector prints the exact ID, or `Default JDK unset: no JDKs are installed`
and exits 0. A dangling managed reference reports an unavailable-default error.
With a selector, exact IDs take precedence; major and distro-major selectors
must resolve to one complete local installation. Bare majors match all distros.
Success prints `Default JDK set to: <ID>` to stdout. No networking or cache access is involved.
`default --help` uses the main help without accessing storage or external tools.

Installation initializes an absent default after successful publication, including
an idempotent install of an existing ID. It never replaces an existing reference
or unrelated data at that path. Link failure returns 1 and explains that the JDK
was installed but default selection failed; the installed JDK is retained.
Concurrent initialization creates the final link directly without replacement:
the first creator wins. No shared-storage lock is introduced.
The installer that creates the default also prints `Default JDK set to: <ID>`
on stdout, before its installation success/already-installed message. Subsequent
installs and losing concurrent initializers do not announce a default change.

When uninstalling the default, choose from the remaining complete compatible
inventory: first the same major, then the smallest higher major, then the largest
lower major. Ties use the first ID in local inventory order (C-locale directory
name order). This orders only extracted majors, never vendor version strings.
If no JDK remains, remove the link/junction. After successful removal, print
`Default JDK set to: <ID>`
for a replacement, or `Default JDK unset: no JDKs are installed` if the inventory is now empty.
These lines follow the uninstall success message on stdout. Failed removals
do not announce a successful default change. Change the reference before moving
the old installation so it never intentionally points to a removed JDK. If the
move fails, restore the old selection provided the replacement is still current.
A failed default change aborts removal. Interruption between selection and removal
can leave the old installation present with the replacement already selected.

Explicit replacement stages and verifies a real link in `jvm/tmp/default.XXXXXXXX`,
then uses GNU-compatible `mv -fT` when advertised or BSD `mv -fh` to avoid following
the destination link. Never replace an unrelated file, directory, or link outside
the managed inventory. `readlink` is required for inspecting existing references;
Unix creation requires `ln`; Windows requires `cygpath` and `cmd.exe`.
Windows creation runs fixed `mklink /J` text with quoted environment values and
delayed expansion disabled. No directory-copy fallback is permitted. Junctions
avoid the special symlink privilege requirement; filesystem/access errors still
fail explicitly. See [Microsoft's mklink reference](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/mklink)
(checked 2026-10-30).

Unix rename replacement is atomic with the supported utilities. A staged recovery
link preserves the prior usable selection if replacement fails or a catchable
signal arrives after the old reference disappears. If restoration itself fails,
retain that link and report its recovery path. Windows junction replacement was
verified with Git Bash's native `mv`; crash atomicity inside Windows/MSYS rename
is not established. An uncatchable kill in a non-atomic replacement window can
require manual recovery from `jvm/tmp/default.XXXXXXXX/previous`.
Simultaneous explicit default changes use last successful
publication; there is no transaction spanning independent install/uninstall/default
processes. Native Cygwin/MSYS2 and macOS replacement remain verification gaps.

## Metadata API

Use [jdkdb-index API](https://jbangdev.github.io/jdkdb-index/) as the discovery
source and the artifact URLs it returns for downloads. Isolate API normalization
from selection and installation so schema changes remain contained.

### Observed contract (2026-10-19)

The published [OpenAPI definition](https://jbangdev.github.io/jdkdb-index/openapi.yaml)
documents static files including:

- `/metadata/all.json` and `/metadata/{distro}/all.json`.
- `/metadata/{release_type}/{os}/{arch}/{image_type}.json`, with progressively
  narrower paths adding JVM implementation, distro, major version, and file type.
- `/metadata/{release_type}/{os}/{arch}/{image_type}/{jvm_impl}/{distro}/{version}/{file_type}-latest.json`.
- The same final path ending in `-latest-url.txt`, returning download URLs.
- `/metadata/{distro}/{artifact_name}.json` and
  `/checksums/{distro}/{artifact_name}.{hash_algorithm}`.

A Linux Temurin 21 latest JSON response and the corresponding Windows ZIP
latest-URL response were retrieved successfully during specification research.
This is not evidence that every documented combination exists or that the API
is stable. HTTP and transfer failures remain distinct from an empty listing;
discovery now trusts successful response contents as described below. Do not
infer a server-side query API from static paths.

Fields include distro, filename, file type, Java/vendor versions, platform, image
type, JVM implementation, features, URL, size, and checksum fields. The schema
does not declare these all required. Discovery trusts the TSV layout below;
unused fields are ignored. No stable ID or structured version sort
key is documented. The TSV design below supersedes JSON as the planned input.

### Published TSV contract (verified 2026-10-20)

The API provider can offer alternative formats and subsets of existing JSON
metadata, but no new information, `jvm`-specific IDs, or ordering keys. Construct
IDs in `jvm` and use upstream latest semantics. The published
[OpenAPI definition](https://jbangdev.github.io/jdkdb-index/openapi.yaml) now
documents TSV endpoints and their `metadataTsv` schema. The
[Linux x86_64 latest index](https://jbangdev.github.io/jdkdb-index/metadata/all/linux/x86_64/jdk-latest.tsv)
was retrieved and inspected, along with the GA-only latest index and the
all-release full-history index.

Use one broad platform-specific latest index, filtering distro, major, and
compatible artifacts locally for every discovery selector, retaining all JVMs.
Avoid requiring additional indexes for every distro or selector. The documented paths are:

```text
/metadata/{release_type}/{os}/{arch}/{image_type}-latest.tsv
/metadata/{release_type}/{os}/{arch}/{image_type}.tsv
```

For initial GA-only behavior, use
`/metadata/ga/{os}/{arch}/jdk-latest.tsv`. The user's example uses `all`, which
can include EA rows: the API prefers GA over EA for a given major/distribution/
JVM implementation, but does not exclude EA altogether. Latest means the latest
release per major version for each distro and JVM implementation. The full
history counterpart omits `-latest`; a future all-versions option can use it.
OS tokens follow the API, including `macosx` and `linux-musl`. Validate actual
host-specific coverage before claiming support.

Files are UTF-8 with a header. A subsequent 2026-10-20 retrieval confirmed that
`version` and `file_type` have been added. There are now 15 columns, in this
exact published order:

| Column | Field | Purpose |
| --- | --- | --- |
| 1 | `release_type` | Validate GA/EA selection. |
| 2 | `os` | Validate host compatibility. |
| 3 | `architecture` | Validate host compatibility. |
| 4 | `image_type` | Require a JDK image. |
| 5 | `jvm_impl` | Display only; not filtered or included in IDs. |
| 6 | `vendor` | Publisher metadata; use `distro` for selectors. |
| 7 | `distro` | Display, distro filtering, and ID construction. |
| 8 | `java_version` | Upstream Java version; ignored by discovery. |
| 9 | `version` | ID construction, displayed version, and major matching. |
| 10 | `file_type` | Archive format used for filtering and extraction. |
| 11 | `url` | Artifact download location. |
| 12 | `filename` | Source artifact filename. |
| 13 | `size` | Expected artifact size in bytes. |
| 14 | `sha256` | Expected download digest. |
| 15 | `features` | Distinguish artifact variants sharing an ID. |

The API provider confirms that every TSV field is populated. The OpenAPI schema
also permits empty missing text fields; this historical contract discrepancy is
recorded as upstream information, not a reason to validate the index in `jvm`.
The project creates and maintains this index: errors should be fixed upstream.

**Adopted on 2026-10-29:** trust the published TSV contents. Discovery MUST NOT
validate headers, column counts, populated fields, version/ID tokens, checksums,
URLs, or feature-list syntax, either when fetching or on cached reads. It uses
the documented fixed column positions and skips the first (header) record. A
successful nonempty HTTP 200 body is cached as received. Empty/missing bodies
are handled as transfer/cache availability failures, not schema validation.
Schema or content errors may affect listings until corrected upstream.

Backslashes, tabs, carriage returns, and newlines in text fields are published
as backslash escapes (`\\`, `\t`, `\r`, `\n`). Discovery reads only canonical
listing fields, which need no escape decoder, and leaves unused text untouched.
Literal tabs remain field boundaries (including empty fields). CRLF record
endings are stripped. Data is never evaluated or sourced as shell code.

Use `release_type`, OS, architecture and image type for GA/host/JDK filtering.
Use `jvm_impl` for display only, without filtering it or including it in IDs.
Use `file_type` for `tar.gz`/`zip` filtering. The bracketed
features field is inspected only for a `musl` feature on a non-musl host; it is
not parsed or compared as build metadata. `version` supplies IDs, the displayed
version and major matching. Major extraction accepts both modern versions such
as `8.0.482+8` and legacy `1.8.0_482-b08` notation. `java_version`, vendor, URL,
filename, size and SHA-256 are ignored by discovery.

Print each matching ID once in upstream order. Duplicate IDs, including archive
or feature variants and different builds, do not trigger comparison, warnings,
or failures. This supersedes both earlier fatal-collision handling and its later
warning-only policy. Installation separately requires a unique candidate row
after the adopted archive-format preference.

Use a single ordinary text-filtering utility pass for filtering, ID construction
and deduplication. Avoid Bash row-by-row validation and quadratic build-comparison
loops. Runtime logic stays in the single Bash file, using ordinary utilities;
no general JSON parser or language runtime is introduced.

### Metadata caching

`jvm` manages its own persistent index cache beneath
`${XDG_CACHE_HOME:-$HOME/.cache}/jvm/`; curl/wget downloads alone are not a cache.
Keep cache entries and validators associated with the exact index URL so that
different platforms and latest/all indexes cannot be confused.
The inspected latest endpoint returned both ETag (a weak validator, `W/"..."`)
and Last-Modified headers, as well as `Cache-Control: max-age=600`. Preserve ETag
quoting and its weak prefix verbatim in conditional requests; do not treat the
ETag as a download checksum. These observed headers may change.

A usable cache has matching internal URL/time metadata and a nonempty body.
This checks our cache envelope, not the provider's TSV contents. Cached TSV is
never schema-checked or parsed until the single listing/filtering pass.

- Reuse a recently checked valid index without network access. **Adopted:**
  refresh after one hour (3600 seconds), adopted for this milestone.
- Prefer conditional GET over a separate HEAD request followed by GET. Save the
  server's ETag and send `If-None-Match`; use Last-Modified/If-Modified-Since
  when ETags are unavailable. Treat validators as opaque server data.
- A `304 Not Modified` reuses the valid cached index. A `200 OK` supplies a
  replacement without TSV validation. If a 304 arrives without a usable cached
  body, retry without a condition rather than treating missing data as success.
- Store the last successful check time separately from the server modification
  time. A 304 updates the check time; a failed refresh does not.
- Download to a temporary file, then atomically publish a successful nonempty
  HTTP 200 body with matching validator metadata. Failed transfers and empty
  bodies must not overwrite an existing cache. Do not inspect the TSV contents.
- If any conditional check or subsequent refresh download fails and a valid
  cached index exists, silently use it. Do not fail the command or display an
  update-failure/stale-cache warning. A nonempty HTTP 200 replacement is trusted,
  even if its contents would previously have failed TSV validation.
  Report later operational failures, such as an unavailable JDK artifact, if
  they actually occur; do not substitute the earlier cache-refresh failure.
- Without a valid cached index, a failed fetch remains an actionable error.
  Never turn transfer failure into an empty inventory or successful no-match.
- Detect downloader capabilities rather than assuming every wget is GNU Wget or
  requiring recent curl ETag convenience options. Send conditional headers with
  supported options, normalize response handling in the transfer adapter, and
  fall back to an unconditional GET when conditional transfers are unsupported.
- Bound transfer retries/timeouts even when falling back to cache. A future
  PowerShell implementation should retain the same HTTP/cache behavior.
  Curl uses a 45-second metadata limit and a 30-minute artifact limit; wget
  uses a 15-second connection/read timeout with one attempt in both cases.

## Download and installation behavior

- Use HTTPS with certificate validation for metadata, artifacts, and redirects;
  never disable TLS verification or silently downgrade to HTTP.
- Handle metadata transfer failures according to the silent cached
  fallback rules above. Artifact transfer failures remain errors. Bound retries
  and timeouts and reject incomplete downloads.
- Before downloading a JDK, require the expected SHA-256 digest from the index
  and an available verifier. SHA-256 is the single agreed TSV checksum column;
  detect utilities such as `sha256sum`, `shasum -a 256`, or `openssl dgst
  -sha256` and normalize hexadecimal case for comparison. A future PowerShell
  port can use `Get-FileHash -Algorithm SHA256` with the same index.
  Do not silently fall back to MD5/SHA-1 or unverified installation. Reject
  mismatches; validate advertised size when present.
- Stage downloads and extraction in private temporary locations. Validate archive
  entries and links against absolute paths, traversal, and writes outside the
  staging tree; preserve legitimate internal JDK links. Do not run installers
  or metadata-provided commands.
- Verify the extracted JDK layout before publishing a complete installation.
  Final publication must stay on the same filesystem for atomic rename.
- Install concurrently using independent temporary directories and a final
  same-filesystem rename. A losing publisher succeeds when a complete compatible
  installation of the same ID was published by another installer. Do not use a
  shared-storage lock.
- Failed/interrupted installation must leave existing JDKs and the default
  usable. Clean up only temporary paths owned by that operation. Partial installs
  must never appear in `list` or resolve as usable JDKs.
- Quote paths and handle spaces and shell metacharacters in HOME, XDG paths,
  project paths, and download data. Do not use `eval` or source manifests, API
  responses, config, or JDK `release` files.
- Use user-owned locations without sudo/admin installation. No telemetry or
  unrelated network traffic is required.

## Acceptance criteria

The complete version is ready when the following hold. These are not claims
that native verification is complete on every supported platform:

1. A copied `jvm` script can list/download/install a JDK without Java already
   installed and without a language runtime or `jq` dependency.
2. All three selector forms work locally; ambiguous and missing matches give
   actionable errors. Remote short selectors follow documented resolution.
3. A downloaded JDK has a verified strong digest and usable compiler/runtime.
   Reinstalling its ID succeeds without duplicate installation or redownload.
4. Listing and default selection work offline from durable metadata.
5. Selecting a default updates the stable PATH/JAVA_HOME reference; the setup
   works on Linux/macOS and supported Windows link configurations. Link failure
   preserves the prior selection and gives a useful diagnostic.
6. curl-only and wget-only configurations work. Missing extractors/verifiers,
   corrupted downloads, hostile/malformed metadata or archives, concurrent
   processes, and interruptions fail without corrupting managed state.
7. Platform/libc detection, macOS bundles, Windows paths, Bash 3.2 compatibility,
   spaces in paths, and nondefault XDG locations are covered by verification.
8. Session selection and command execution remain unimplemented.
9. TSV discovery trusts the published layout, uses explicit `file_type`, and
   lists compatible latest JDKs across JVM implementations. Unused fields stay
   untouched; repeated IDs display once without build checks or warnings.
   Conditional 304 responses reuse the cache; failed refreshes silently retain
   cached data, while initial-fetch failure without a cache is an error.

## Decisions to revisit before declaring full platform support

- Verify junction replacement and interruption behavior in native Cygwin/MSYS2.
- Keep general JSON parsing deferred as a last resort. Artifact preference is
  adopted above; no feature or JVM preference is introduced.
- Record actual platform/architecture coverage; a simulated detection test does
  not establish that native extraction, linking, and Java execution work.


## Latest-index selection verification (2026-10-30)

Re-inspected the live [OpenAPI definition](https://jbangdev.github.io/jdkdb-index/openapi.yaml).
Its latest TSV endpoint groups by JVM implementation, distro, Java major and
file type, retaining entries tied at the highest version. Selection therefore
filters that inventory and asks for an exact ID when more than one ID matches;
it does not add another version-ordering policy. This implements the user's
explicit latest-index clarification and supersedes the earlier comparator.

Retrieved representative GA latest indexes directly over HTTPS:

| Platform response | Data rows |
| --- | --- |
| [Linux x86_64](https://jbangdev.github.io/jdkdb-index/metadata/ga/linux/x86_64/jdk-latest.tsv) | 487 |
| [Linux aarch64](https://jbangdev.github.io/jdkdb-index/metadata/ga/linux/aarch64/jdk-latest.tsv) | 362 |
| [Linux musl x86_64](https://jbangdev.github.io/jdkdb-index/metadata/ga/linux-musl/x86_64/jdk-latest.tsv) | 138 |
| [macOS x86_64](https://jbangdev.github.io/jdkdb-index/metadata/ga/macosx/x86_64/jdk-latest.tsv) | 523 |
| [macOS aarch64](https://jbangdev.github.io/jdkdb-index/metadata/ga/macosx/aarch64/jdk-latest.tsv) | 428 |
| [Windows x86_64](https://jbangdev.github.io/jdkdb-index/metadata/ga/windows/x86_64/jdk-latest.tsv) | 468 |
| [Windows aarch64](https://jbangdev.github.io/jdkdb-index/metadata/ga/windows/aarch64/jdk-latest.tsv) | 112 |

Supported-archive JDK rows contained 235 distinct upstream version strings.
The checked-in `tests/fixtures/upstream-versions.tsv` retains each version with
a representative distro and java_version. Examples include `22.3.3+java17`,
`22.1.0.1-Final`, `17.0.18+8_openj9-0.57.0`, `21.0.11b1163.125`, `10.0.2+13.1`
and `8u462-b08_1`. Offline selection tests use all these captured forms with
inert archive metadata; they make no live artifact downloads and do not claim
those artifacts are installable on the verification host. Latest-index
selection, source version strings, IDs and archive preference are kept separate.

## Discovery research and implementation record (2026-10-29)

The live [OpenAPI definition](https://jbangdev.github.io/jdkdb-index/openapi.yaml)
and these GA latest responses were retrieved directly over HTTPS on 2026-10-29:

| Platform response | HTTP | Data rows |
| --- | --- | --- |
| [Linux x86_64](https://jbangdev.github.io/jdkdb-index/metadata/ga/linux/x86_64/jdk-latest.tsv) | 200 | 467 |
| [Linux aarch64](https://jbangdev.github.io/jdkdb-index/metadata/ga/linux/aarch64/jdk-latest.tsv) | 200 | 361 |
| [Linux musl x86_64](https://jbangdev.github.io/jdkdb-index/metadata/ga/linux-musl/x86_64/jdk-latest.tsv) | 200 | 140 |
| [macOS aarch64](https://jbangdev.github.io/jdkdb-index/metadata/ga/macosx/aarch64/jdk-latest.tsv) | 200 | 413 |
| [Windows x86_64](https://jbangdev.github.io/jdkdb-index/metadata/ga/windows/x86_64/jdk-latest.tsv) | 200 | 441 |
| [Windows aarch64](https://jbangdev.github.io/jdkdb-index/metadata/ga/windows/aarch64/jdk-latest.tsv) | 200 | 109 |

Every retrieved data row had exactly 15 nonempty fields, in the published header
order above. The schema still explicitly permits empty missing text fields;
that remains a conflict with the previously recorded provider-confirmed
populated-field contract. Discovery now trusts the index and does not reject
unexpected empty fields. `[]` is populated and valid. The OpenAPI definition
still documents the four backslash escapes and bracketed feature notation.
Retrieved samples used LF. Current fixtures cover CRLF transport and leaving
unused escaped fields untouched. No naturally escaped text appeared in these
six samples; discovery does not decode unused fields.

Representative values included `1.8.0_482-b08`, `17.0.20+1-LTS`, and `11.0.32.b1`.
These historical `java_version` samples describe upstream data, not current ID
inputs. On 2026-10-30 the user adopted `version` for IDs, display and major
matching. `java_version` is now ignored; build comparisons remain removed.
Linux x86_64 returned ETag `W/"6ae33697-2234d"`; this is an observation, not a
stable value. Header validators are preserved as opaque strings.
The Windows x86_64 latest response had a Temurin 21 MSI row and no supported
Temurin 21 ZIP/tar.gz row. Thus `available temurin-21` correctly returned no
match on that host during the live check. The adapter does not invent an archive
URL or switch to a history endpoint. `available temurin-8` succeeded there.
Endpoint availability and the historical record checks do not prove download availability
or native platform compatibility.

### Adopted discovery details and remaining gaps

- `uname` detects Linux, Darwin and Windows CYGWIN/MSYS/MINGW environments;
  WSL reports Linux. AMD64/x86_64 and ARM64/aarch64 normalize to API tokens;
  32-bit x86 normalizes to `i686` (the live schema token). `ppc64le`, `s390x`
  and `riscv64` are recognized without claiming verified endpoint coverage.
  ARMv7 is rejected because `uname` alone does not establish the supported ARM
  ABI (`arm32` versus `arm32-vfp-hflt`). Unknown machines fail explicitly.
- Linux detection uses musl/glibc identification from `ldd --version`, with
  `getconf GNU_LIBC_VERSION` as a glibc fallback. Unknown libc fails. Musl targets
  `linux-musl`; musl-feature artifacts are excluded on other hosts. Actual ABI
  compatibility and emulation detection beyond process architecture need native
  verification before broader support claims.
- In the original discovery milestone, cache storage alone was used. Only the
  needed cache XDG root is resolved by discovery;
  relative/empty overrides fall back to an absolute HOME. Windows drive paths
  use `cygpath`; no data/config/state directories or shell profiles are created.
- Each platform cache file includes the exact URL, successful check time, ETag,
  Last-Modified and raw TSV body in one versioned entry. A private same-filesystem
  staging directory and a single file rename publish body and validators
  together. Readers see a complete generation; concurrent refreshes may perform
  duplicate work and the last complete publication wins. No JDK storage lock is
  needed in this read-only discovery milestone. Timestamps in the future are
  rechecked; failed refreshes preserve the previous entry and check time.
- Curl uses HTTPS-only redirect restrictions and connect/total timeouts. Wget
  capability detection requires `--https-only`, uses response headers and bounded
  retries/read timeouts, and omits conditional headers if `--header` is absent.
  A wget without safe HTTPS redirect support fails actionably; it is not assumed
  to be GNU Wget. At most two GET attempts cover a 304 with no usable cached body.
- Artifact preference and installed manifests were subsequently implemented in
  0.2.0 as described above. Version ordering was removed following the user's
  latest-index clarification. Windows defaults now use junctions; general JSON
  parsing remains deferred.
- Verification to date: Bash syntax validation, the deterministic offline suite,
  and native Git Bash 5.3 discovery with curl plus a second cached invocation.
  Other host cases and both downloader adapters are simulated by the suite.
  Bash 3.2 and ShellCheck were not available; Linux, macOS, Cygwin and standalone
  MSYS2 native runs remain unverified. No archive/execution/linking support is
  claimed by discovery checks.
