# Discovery, installation and uninstallation verification

Run from the repository root in Bash (3.2 or later):

```bash
bash -n ./jvm
bash -n tests/run.sh
bash -n tests/live-smoke.sh
bash -n tests/install.sh
bash -n tests/home-env.sh
bash -n tests/default-native-windows.sh
bash tests/run.sh
# Installation-only checks:
bash tests/install.sh
# Focused list/install/uninstall selector checks:
bash tests/install.sh --selectors
# Focused interruption/publication-race checks:
bash tests/install.sh --publication
# Focused flags and aliases checks:
bash tests/install.sh --flags
# Focused offline home/env checks:
bash tests/home-env.sh
# Focused offline list/uninstall checks:
bash tests/install.sh --uninstall
```

The offline suite creates temporary HOME and XDG roots, including paths with
spaces. Its isolated PATH supplies ordinary utility wrappers and fake host,
curl and wget commands. It makes no network calls, downloads no JDKs, and never
reads or writes normal JDK inventories, defaults, or shell profiles. It requires
the ordinary tools used by `jvm`, plus `chmod` to prepare executable fakes.
`tests/run.sh` runs discovery checks, the installation suite, then home/env
checks, stopping if a suite fails.
Temporary files are cleaned on completion or interruption. Runtime code is only
`jvm`; no fixtures or tests need distribution.

Per-major default coverage (2026-11-01) uses `tests/install.sh --defaults` and
`tests/home-env.sh`. It checks the `jdks/default` and `jdks/<major>` references,
independent selection, major mismatch rejection, initialization and replacement,
stable global home/env output, major-reference precedence with inventory fallback,
ambiguity tables, and read-only query behavior. The general suite also
exercises concurrent initialization and failed moves. Windows path conversion
in the home/env suite is simulated; `tests/default-native-windows.sh` is the
optional native junction check on a Windows Bash host.
On 2026-11-01, `bash tests/run.sh` passed all 56 discovery checks, 18
installation checks and the home/env suite under native Git Bash on Windows.
`bash tests/default-native-windows.sh` also passed junction creation, traversal,
replacement and removal in isolated storage. Bash 3.2, Linux, macOS, Cygwin and
standalone MSYS2 native runs remain unverified; ShellCheck was unavailable.

Home/env selector correction (2026-11-01): explicit major, distro-major and ID
selectors return a selected installation's physical home. Positive majors first
use an existing valid per-major reference without scanning other installations
and retain its stable link path in output, including with `-i`;
absent references fall back to inventory selection and physical homes. The home/env suite covers
missing, unrelated, dangling and wrong-major references, legacy majors and
ambiguity without a major default. The `--flags` checks cover offline `-i`
selection with and without a major link, ambiguity without networking, and
returning the exact installed ID after installation races.

Optional development checks, only when installed:

```bash
shellcheck -s bash jvm tests/run.sh tests/install.sh tests/live-smoke.sh
/path/to/bash-3.2 -n ./jvm
/path/to/bash-3.2 tests/run.sh
/path/to/bash-3.2 tests/install.sh
wc -c < jvm
```

The test harness invokes the same Bash interpreter used to launch it. A newer
Bash's compatibility mode does not substitute for running Bash 3.2.

Separate optional network smoke check (still isolated HOME/XDG):

```bash
bash tests/live-smoke.sh
# Or supply a selector with a supported archive on this host:
bash tests/live-smoke.sh temurin-21
bash tests/live-smoke.sh temurin
```

Without a selector this checks the full inventory, silently collapsing repeated IDs. Live inventory changes can make a selector
unavailable;
a no-match error is not an empty successful listing. This check uses the real
host and installed downloader, then lists again from its temporary cache. It
does not install or execute Java. It is excluded from the ordinary suite.

On Windows PowerShell, use a real Bash executable, for example:

```powershell
& 'C:\Program Files\Git\bin\bash.exe' -n ./jvm
& 'C:\Program Files\Git\bin\bash.exe' tests/run.sh
& 'C:\Program Files\Git\bin\bash.exe' tests/install.sh
& 'C:\Program Files\Git\bin\bash.exe' tests/live-smoke.sh
```

Syntax checks and the offline suite run under Git Bash 5.3.15. Native Git Bash/
curl discovery and cached reuse were verified on 2026-10-29. The offline suite
also checks
purpose, command descriptions and examples in main/subcommand help,
distro/major/distro-major selectors on the same
latest cache, all JVM implementations with short version-distro IDs, rejection of exact-ID
selectors, trusted metadata without validation and silent ID deduplication.
Listing checks expand 8-column tab stops to verify alignment, including IDs
around tab boundaries, long IDs, filtered results and the header-only case.
Padding targets stop at four tab stops; longer values overflow with one tab.
The four displayed columns are ID, distribution, version and JVM; platform
selection is checked through endpoint requests rather than a displayed column.
It covers simulated Linux glibc/musl, macOS ARM64,
Cygwin, MSYS2 and Git Bash host identities. Simulations verify normalization and
filtering, not native utility behavior or binary compatibility. Bash 3.2 and
ShellCheck were unavailable. Native Linux, macOS, Cygwin and standalone MSYS2
checks remain outstanding. There is no CI configuration or claimed CI result.

The fixtures deliberately keep `version` different from `java_version`.
`version-source.tsv` exercises IDs, display, major filters and deduplication
using `version`, including modern and legacy notation. Fixture-generated
alignment and cache-replacement tests modify that same column. This prevents
accidentally restoring the earlier `java_version` behavior.

`jvm-impls.tsv` includes HotSpot, OpenJ9 and GraalVM with the same version and
distribution, plus an archive duplicate. Their shared version-distro ID displays
once without a JVM suffix or diagnostic. The first matching row supplies display
fields; reversing row order verifies no HotSpot preference is applied. Major,
distro and distro-major selectors use the same cache without additional requests.

`tests/install.sh` is a separate deterministic offline suite with isolated
HOME/XDG/PATH and fake curl/wget transfers. It uses real tar/gzip, Info-ZIP unzip
and sha256sum/openssl against tiny checked-in inert JDK archives. It does not
execute Java. Fixtures include safe internal links and hostile traversal, link
ancestors, escaping links, duplicate entries and cycles. The suite also covers
selectors without version ordering, multi-ID ambiguity, format preference/fallback, manifest persistence,
checksum/size/transfer/layout failures, idempotence, interrupted/concurrent
installation, losing-publisher success, and preservation of prior installs
and unrelated default data. Windows and macOS host/layout cases are simulated;
extractors run natively in the Bash environment running the tests.

`tests/generate-archives.py` is an optional contributor-only Python fixture
generator. The runtime and offline suites never invoke Python. To regenerate:

```text
python tests/generate-archives.py
```

The checked-in fixtures are tiny and deterministic. A duplicate-name warning is
expected when generating the deliberately hostile duplicate ZIP. No optional
live installation check is bundled; the existing live smoke only discovers.

The installation suite requires tar/gzip, Info-ZIP unzip, sha256sum and openssl
as development tools. Its shasum CLI fallback is simulated with a wrapper around
sha256sum; the native shasum executable was unavailable in the verification
environment. This does not add runtime dependencies to the distributed script.

Verification on 2026-10-30: syntax checks for `jvm` and all three Bash test
scripts passed under Git Bash 5.3.15. The combined offline suite passed 56
discovery checks and 11 installation groups before removing the comparator.
Those hand-picked fixtures missed other vendor version forms, including
`22.3.3+java17`. The subsequent user clarification removed ordering entirely;
see the captured upstream coverage below. `git diff --check` passed. No live JDK was
downloaded or executed. Native Linux, macOS, Cygwin, standalone MSYS2 and Bash
3.2 verification remain outstanding; ShellCheck was unavailable. Simulated
Windows .exe files validate layout, not native executable behavior.

`fixtures/upstream-versions.tsv` captures 235 distinct upstream versions from
seven GA latest indexes inspected on 2026-10-30: Linux x86_64/aarch64, Linux-musl
x86_64, macOS x86_64/aarch64 and Windows x86_64/aarch64. Each keeps a representative
distro and java_version alongside the actual version string. The installation
suite supplies inert archive metadata, checks explicit distro-major selectors
6 through 27 using a synthetic `observed` distro containing every captured
version, requires explicit choices when several IDs match, and verifies that ambiguity
downloads no artifact. Both reported GraalVM IDs are checked explicitly. The
fixture has no live-network dependency and does not claim archive availability.

Separate tests verify that `install 22` and `install temurin-22` resolve to the
same ID even with GraalVM alternatives present, that an explicit distro overrides
the default, and that missing Temurin matches never fall back to another vendor.
`available 22` remains a broad discovery listing.

After comparator removal, the combined suite passed 56 discovery checks and
12 installation groups. After adding the Temurin default, `bash -n ./jvm`,
`bash -n tests/install.sh` and `bash tests/install.sh --selectors` passed (five
focused groups, including all 235 captured versions). `git diff --check` passed.

Home-layout checks cover publication directly into `<ID>/bin`, preservation of
hidden files and internal links, rootless and deeply wrapped archives, macOS
`Contents/Home`, and simulated Windows extensionless/.exe/.bat/.cmd launchers.
They reject multiple homes, links that would escape after flattening, and
archive-provided manifests. Current v2 manifests record `.` as the JDK home.
Installation messages are checked on stderr/stdout, including
the successful and already-installed sentences. These fixtures remain inert;
the tests never execute Java or Windows batch files.

Flat-home verification on 2026-10-30: Bash syntax checks passed for `jvm`,
`tests/run.sh` and `tests/install.sh`; the combined offline suite passed all
56 discovery checks and 15 installation groups under Git Bash 5.3.15.
`git diff --check` passed. The distributed script measures 30,490 bytes.
Native Linux/macOS/Cygwin/standalone MSYS2 and Bash 3.2 remain unverified;
Windows/macOS layout cases are simulations, not native Java execution checks.

After removing backward compatibility, Bash syntax checks and
`bash tests/install.sh --selectors` passed (five focused groups, including
installation, offline listing, idempotent reinstall and captured upstream
versions). `git diff --check` passed. Script size: 30,181 bytes.

Publication uses independent `tmp/jdk-<ID>.XXXXXXXX` staging directories next to `jdks/`
and ordinary `mv`, without storage locking. The focused `--publication` test
pauses two fully prepared installers after their last destination check. It
publishes one, lets the other's `mv` create a uniquely named nested copy, then
checks that the copy is first renamed back into private staging and deleted
there, identical success messages, preservation of a winner
marker, distinct staging names and removal of temporary publication markers.
The fake cleanup utility rejects any recursive removal inside `jdks/`, and the
test asserts that `jdks/tmp` was never created.
It also checks interruption cleanup and a genuine move failure without a winner.
This exercises the folder-nesting behavior using the installed native `mv`;
it does not claim a native macOS/BSD verification run.

Uninstall checks run as part of the full suite or with `--uninstall`. They use
real directory moves and isolated storage with spaces, disable downloaders and
remove the metadata cache, and cover exact IDs, majors across all installed distributions,
distro-major selectors, legacy versions, ambiguity and no matches.
The fake `rm` rejects recursive deletion beneath `jdks/`. Move failures preserve
the installed JDK; a simulated deletion failure leaves the detached JDK in its
private removal directory. A simulated Windows host checks the in-use hint.

Uninstall verification (2026-10-30): Bash syntax checks passed for `jvm`,
`tests/run.sh` and `tests/install.sh`. The discovery suite passed all 56 checks;
after correcting test setup order, the install/uninstall suite passed all 15
groups under Git Bash. `git diff --check` passed. Script size: 31,528 bytes.
The native platform and Bash 3.2 verification gaps above remain unchanged.

After correcting bare-major uninstall selection to cover every installed
distribution, Bash syntax checks and `bash tests/install.sh --selectors` passed
(six focused groups, including cross-distribution uninstall ambiguity and the
unchanged Temurin default for install). `git diff --check` passed. Script size:
31,602 bytes. These checks retain the platform verification gaps above.

Restored `list [selector]` verification (2026-10-30): Bash syntax checks passed
for `jvm`, `tests/run.sh` and `tests/install.sh`; the focused `--selectors` suite
passed seven groups under Git Bash. Listing checks cover full IDs, majors across
distributions, distro and hyphenated distro-major filters, legacy versions,
multiple results, no matches and invalid arguments with downloaders disabled
and the cache absent. Main and list help agree. `git diff --check` passed.
Script size: 32,013 bytes. Existing native platform and Bash 3.2 gaps remain.

Ambiguity listings (2026-10-30): `list` and install/uninstall ambiguity reports
share the same table renderer. Tests check diagnostic candidate IDs and that
remote install candidates appear
once per ID despite multiple archive rows. Bash syntax checks and all seven
focused `--selectors` groups passed under Git Bash; `git diff --check` passed.
Script size: 32,454 bytes. Existing native platform and Bash 3.2 gaps remain.

Empty inventory messaging (2026-10-30): list checks require exactly
`No JDKs are installed. Use 'install' to install one` on stdout with exit 0 and no
stderr, both without a selector and with major, distro, distro-major and full-ID
selectors. Invalid usage still fails; a nonempty inventory with no selector
match still reports the no-match error. Bash syntax checks and all seven focused
`--selectors` groups passed under Git Bash; `git diff --check` passed. Script
size: 32,624 bytes. Existing native platform and Bash 3.2 gaps remain.

No-argument install guidance (2026-10-30): syntax checks for `jvm` and
`tests/run.sh` passed. The harness's focused help/usage group passed with its
isolated HOME/XDG paths and external utilities unavailable on PATH. It checks
exit 2, empty stdout, selector examples, the Temurin default, and guidance to
find full IDs using `jvm available`. `git diff --check` passed.

Install-specific explicit help (2026-10-30): syntax checks and the focused
help/usage group passed under Git Bash. With external utilities unavailable,
`install --help` returned 0, printed exactly the same
text as no-argument install guidance on stdout, and left stderr empty. The
no-argument form retained exit 2 and stderr output. `git diff --check` passed.

Restored main install help (2026-10-30): the later user decision supersedes the
install-specific guidance above. The focused help group now checks the exact
two-line no-argument usage message and that `install --help` equals the main
help page. Syntax checks and that group passed under Git Bash with external
utilities unavailable on PATH. `git diff --check` passed.

Lock-free publication verification (2026-10-30): syntax checks passed for `jvm`,
`tests/run.sh` and `tests/install.sh`; the complete offline suite passed all
56 discovery checks and 14 installation groups under Git Bash 5.3.15. The
focused `--publication` check also passed, including actual nested-copy cleanup.
`git diff --check` passed. Distributed script size: 30,221 bytes. Native platform
and Bash 3.2 verification gaps remain as described above.

Sibling-staging cleanup verification (2026-10-30): `bash -n ./jvm`,
`bash -n tests/install.sh`, `bash tests/install.sh --publication` and
`git diff --check` passed. The race test verifies moving the nested copy back
into its own `jvm/tmp/` staging area before deletion, rejects recursive deletion
under `jvm/jdks/`, and confirms that `jdks/tmp` is absent. Script size: 30,345 bytes.

## Persistent defaults (2026-10-30)

The default lifecycle checks run in the full installation suite, or separately:

```bash
bash tests/install.sh --defaults
```

They cover first-install selection, preservation on subsequent installs, offline
exact/major/distro-major selection, ambiguity, list marking, failed/interrupted
replacement (including recovery after the old reference disappears), uninstall
move-failure rollback, concurrent first-default creators, same-major ties, nearest higher
and lower majors, legacy majors, removing the last default, unrelated-file
protection, and retaining an installed JDK when default creation fails.
The ordinary suite simulates Windows `cmd.exe`/`cygpath`; its junction adapter is
not a native Windows claim. Git Bash runs use native symlinks in isolated storage.

An optional native Windows Bash check uses real `mklink /J`, `cygpath`, `mv` and
native executable traversal, with temporary HOME/XDG directories and no network:

```bash
bash tests/default-native-windows.sh
```

It exercises creation, replacement, uninstall fallback/removal, and paths with
spaces, ampersands, exclamation marks and percent signs. Copies of `cmd.exe`
stand in for Java launchers, so this verifies native executable traversal through
a junction, not a downloaded JDK or Java runtime. It does not use the contributor's
installed JDKs or shell profiles. Windows crash atomicity during the underlying
rename remains unverified; failure/interruption injection tests cover both the
boundary before publication and a missing-old-reference window. Native Linux/macOS/Cygwin/standalone MSYS2 and
Bash 3.2 remain outstanding.

Verification on 2026-10-30: the full offline suite passed 56 discovery checks and
17 installation groups under Git Bash. After recovery-link hardening, Bash syntax
checks, the focused `--defaults` suite and the native Windows junction smoke
passed again. `git diff --check` passed. The distributed script is 39,937 bytes.
ShellCheck was unavailable; the native platform/Bash 3.2 gaps above still apply.

Default messaging update (2026-10-30): shell setup now lives only in its own
main-help section, with Unix and Windows Bash examples. Explicit selection and
automatic install/uninstall selection print `Default JDK set to: <ID>`; removing
the last JDK prints `No JDK currently set as the default`. Syntax checks,
`bash tests/run.sh --help-only`, `bash tests/install.sh --defaults` and
`git diff --check` passed. Tests also verify that unchanged defaults and losing
initializers do not announce a change. Script size: 40,087 bytes.

## Offline home/environment output (2026-10-30)

`bash tests/home-env.sh` checks exact ID, major, hyphenated distro-major and
legacy selection, stable-default versus installation paths, ambiguity, missing
matches, absent/broken/unmanaged/unusable defaults, invalid arguments and help.
It uses the existing inert JDK archive fixture, isolated HOME/XDG paths and a
PATH with no downloaders. The metadata cache is absent. Each invocation compares
storage snapshots to verify the default and installed inventory are unchanged.
It checks single-line home output and three-line env output, success stderr and
failure stdout, apostrophes/spaces/dollars/backticks/other shell metacharacters,
child-Bash evaluation preserving that child's original PATH, conversion failures
and rejection of multiline paths. Windows conversion is simulated in this suite.
The optional native junction smoke also checks real `cygpath` home/env output
and evaluation for both a stable junction and an explicit installed home.

Verification on 2026-10-30: syntax checks passed for `jvm`, `tests/run.sh`,
`tests/home-env.sh` and `tests/default-native-windows.sh`. The focused home/env
suite and the full offline suite (56 discovery checks, 17 installation groups,
then home/env checks) passed under Git Bash 5.3.15. The native Windows junction
smoke passed with real path conversion and child-shell evaluation. `git diff
--check` passed. Distributed script size: 43,117 bytes, with LF line endings.
ShellCheck was unavailable. Bash 3.2 and native Linux/macOS/Cygwin/standalone
MSYS2 remain unverified; fixture launchers do not establish real Java execution.

## Primary results and informational messages (2026-10-30)

Installation, already-installed, uninstallation and default-change confirmations
now go to stderr. Listing, current-default queries, home paths and environment
statements retain their primary results on stdout. The installation harness
asserts empty stdout for install/uninstall/default-selection operations and
checks confirmations on stderr, including concurrent publishers and default
initializers. Home/env checks retain their exact output and child-shell
evaluation assertions.

Verification on 2026-10-30: Bash syntax checks for `jvm` and `tests/install.sh`
passed. The full offline suite passed 56 discovery checks, 17 installation
groups and home/env checks under Git Bash. The native Windows junction smoke
also passed. `git diff --check` passed; script size is 43,137 bytes, with LF
line endings. Bash 3.2 and native Linux/macOS/Cygwin/standalone MSYS2 remain
unverified; no real JDK was downloaded or executed.

## Command flags and aliases (2026-10-30)

The full suite includes `tests/install.sh --flags`. It checks every explicit
alias and both flag positions, invalid/duplicate/unsupported options, missing
selectors without utilities or state changes, local matches without transfers,
local ambiguity and storage/utility failures without installation, and ordinary
Temurin fallback after a genuine local miss. It covers new/already-installed
`install -d`, failed/interrupted default replacement, failed installation,
first-install initialization, preservation of existing defaults, offline exact
IDs, and primary stdout versus informational stderr. A competing local match
introduced during download verifies that continuation uses the exact installed
ID. Windows output cases are simulated, with spaces in isolated data paths.

The optional native Windows smoke also exercises `i -d`, `d -i`, `h -i` and
`e <ID> -i`, with real junctions and native/Bash path conversion. Its copied
`cmd.exe` launchers remain inert substitutes for JDKs; it proves no real Java
runtime behavior.

The subsequent 2026-10-30 correction makes `home` return an absolute POSIX path
on Windows too. Simulated tests require successful home output with a failed or
missing `cygpath`, and the native smoke compares home output with the Bash path.
`env` retains native JAVA_HOME and POSIX PATH conversion and evaluation checks.

Final verification on 2026-10-30: `bash -n ./jvm` and syntax checks for all
modified test scripts passed. `bash tests/run.sh` passed 56 discovery checks,
18 installation groups and the home/env suite under Git Bash 5.3.15. The focused
flags suite and the native Windows junction smoke also passed; the corrected
POSIX home policy passed focused home/env and native checks. `git diff --check`
passed. The distributed script measures 45,558 bytes with LF line endings.
ShellCheck and Bash 3.2 were unavailable. Native Linux, macOS, Cygwin and
standalone MSYS2 remain unverified; no real JDK was downloaded or executed.
