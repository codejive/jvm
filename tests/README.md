# Discovery, installation and uninstallation verification

Windows Bash baseline (2026-11-03): Windows uses current Git Bash, MSYS2 and
Cygwin only. The Cygwin Bash 3.2 job, source patch, build dependencies and
temporary interpreter staging have been removed. The local build helper and
CI entry point reject Windows Bash 3.2 requests before building or running tests.
Linux and macOS retain Bash 3.2 coverage. Older verification notes below describe
historical runs, including the Windows Bash 3.2 coverage that has been retired.

CI fixture repairs (2026-11-03): the installation harness resolves its temporary
root to a physical path so hand-created references and exact home/exec
expectations match managed links when temporary paths have aliases (for example
macOS `/var`). The competing-installation fixture
publishes with a directory rename instead of copying relative symlinks, which
can fail on MSYS2. Cygwin CI and the native junction smoke locate System32 with
`cygpath -u -S` instead of relying on the case of a Windows environment name or
an inherited `cmd.exe` PATH entry. The offline tests still hide real utilities.
Focused inventory, flags/aliases and
execution checks passed under installed Git Bash with an aliased temporary root.
Bash syntax checks, workflow lint and `git diff --check` passed. These local
checks do not establish native macOS or Cygwin compatibility.
The newline-path home/env fixture checks the resolved physical path: it rejects
literal CR/LF, or verifies exact single-line output and evaluated environment
statements when a Windows runtime remaps those filename characters.

CI repair verification (2026-11-03): updated stale help assertions and restored
diagnostics/cleanup when the harness deliberately removes utilities from PATH.
Syntax checks for `jvm` and all Bash test scripts, the complete offline suite
(56 discovery checks, 34 installation groups and home/env), and `git diff --check`
passed under installed Git Bash. The Cygwin source patch passed a dry run against
Bash 3.2.57. The serial build and modern Cygwin compatibility adjustments still
need hosted CI verification; no alternative shell was built locally.

Environment usage comments (2026-11-02): Bash and PowerShell now preserve the
invoked command alias and argument order without adding configured or fallback
selectors. The isolated home/env suite and native Windows PowerShell 5.1 and
PowerShell 7 smoke suites passed, including configured ranges, explicit selectors,
aliases, flag ordering and copied usage commands. The focused installation
flags/aliases suite, Bash syntax checks and `git diff --check` also passed.
Other native platforms and Bash 3.2 were not rerun.

Range install reuse (2026-11-02): `bash tests/install.sh --ranges` covers
offline reuse for explicit and configured ranges, aliases, per-major preferences,
C-order fallback, distro filtering, `-d`, local resolution failures and remote
installation only on a genuine miss. The focused range and configuration checks and the native
Windows PowerShell 5.1 isolated smoke suite passed. The PowerShell harness now
runs from its temporary project directory so checkout configuration is ignored.
Bash syntax checks and `git diff --check` passed. Distributed script sizes:
`jvm` 67,383 bytes; `jvm.ps1` 75,231 bytes. Other platforms and Bash 3.2 were
not rerun for this change.

Run from the repository root in Bash (3.2 or later on Unix; current Bash on Windows):

```bash
bash -n ./jvm
bash -n tests/run.sh
bash -n tests/live-smoke.sh
bash -n tests/jdk-smoke.sh
bash -n tests/install.sh
bash -n tests/home-env.sh
bash -n tests/default-native-windows.sh
bash tests/run.sh
# Discovery/listing/cache checks without installation suites:
bash tests/run.sh --discovery
# Focused EA installation, offline selection and default lifecycle:
bash tests/install.sh --ea
# Focused available -t EA/TYPE and unchanged-listing checks:
bash tests/install.sh --types
# Installation-only checks:
bash tests/install.sh
# Focused directory visibility and exact-ID selection/removal checks:
bash tests/install.sh --inventory
# Focused manifest preservation/forward-compatibility checks:
bash tests/install.sh --manifest
# Focused list/install/uninstall selector checks:
bash tests/install.sh --selectors
# Focused range filtering, disambiguation and install-on-demand checks:
bash tests/install.sh --ranges
# Focused interruption/publication-race checks:
bash tests/install.sh --publication
# Focused flags and aliases checks:
bash tests/install.sh --flags
# Focused configuration parsing, defaults and precedence:
bash tests/install.sh --config
# Focused command execution checks:
bash tests/install.sh --execution
# Focused offline home/env checks:
bash tests/home-env.sh
# Focused offline list/uninstall checks:
bash tests/install.sh --uninstall
```

## Native Windows PowerShell implementation

Run the isolated PowerShell 5.1 smoke suite from the repository root:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\powershell.ps1
# Run the same checks against an installed PowerShell 7 executable:
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\powershell.ps1 -PowerShellExecutable 'C:\Program Files\PowerShell\7\pwsh.exe'
```

The suite creates synthetic launchers, manifests, XDG roots, and Windows
junctions only under a uniquely named temporary directory. It does not access
the contributor's JDK inventory, default links, configuration, or profile.
The hosted CI workflow runs it in the `Windows / PowerShell 5.1` job.
Like the Bash harness, it prints `ok <number> - <description>` after each
successful group of checks, followed by a `PASS:` summary with the total count
and target executable. A failed assertion stops the suite with its diagnostic;
the final summary is printed only when all groups pass.
The suite requires Windows PowerShell 5.1 and Windows junction support.
On 2026-11-02, it passed under Windows PowerShell 5.1.26100.9711, covering
offline list/home/env, automatic and per-major defaults, junction
creation/replacement/removal, selected-JDK execution, argument preservation,
and uninstall.
Network transfers and archive installation are not exercised by this smoke
suite.

The home/env and PowerShell suites also check the `Use:` comment's invocation
path and run its suggested command from a relative path containing spaces and an
apostrophe. These checks use only isolated synthetic JDKs.

The stream regression checks invoke the script from a PowerShell prompt using
`>`, `2>` and assignment capture. They cover primary results, empty default
queries, install/default/uninstall confirmations, usage errors, ambiguity
tables, and child stdout/stderr with a nonzero exit code. Assertions also reject
output that bypasses PowerShell redirection through the process console.

Verification on 2026-11-02: the expanded isolated suite passed under Windows
PowerShell 5.1.26100.9711. `bash -n ./jvm` and `git diff --check` passed.
`jvm.ps1` measures 73,362 bytes with LF line endings. Network/archive paths
and other platforms were not validated by this change. Child output is forwarded
as text lines. The later plain-stderr change below supersedes normal error-record
formatting for informational and child stderr output.

Plain stderr (2026-11-02): informational messages now use native-style stderr
records, preserving stream 2 redirection while displaying only message text.
Expected usage and operational failures also display plain messages; only
unexpected program errors retain detailed PowerShell error formatting. The install tests
assert exact confirmation text for exact IDs and range reuse, so source
locations and error headers fail the checks.
The isolated suite passed against both Windows PowerShell 5.1 and PowerShell 7,
including plain usage and I/O failures and retained diagnostics for an injected
program error. Syntax parsing and `git diff --check` passed. The distributed
`jvm.ps1` is 76,384 bytes. Network/archive paths were not exercised.

The offline suite creates temporary working directories, HOME and XDG roots,
including paths with spaces. It never reads the contributor's `.jvmrc` or user
configuration. Its isolated PATH supplies ordinary utility wrappers and fake host,
curl and wget commands. It makes no network calls, downloads no JDKs, and never
reads or writes normal JDK inventories, defaults, or shell profiles. It requires
the ordinary tools used by `jvm`, plus `chmod` to prepare executable fakes.
`tests/run.sh` runs discovery checks, the installation suite, then home/env
checks, stopping if a suite fails.
Temporary files are cleaned on completion or interruption. Runtime code is only
`jvm`; no fixtures or tests need distribution.

## GitHub Actions portability checks

[`.github/workflows/test.yml`](../.github/workflows/test.yml) runs on pushes,
pull requests and manual dispatch. Each matrix entry checks the actual Bash
version, syntax-checks `jvm` and every test script, and runs the full offline
suite. Windows entries also run the native junction smoke.

| Runner | Environment | Interpreters |
| --- | --- | --- |
| `ubuntu-24.04` | Linux/glibc | Private GNU Bash 3.2.57 build; system Bash |
| `macos-15` | Native macOS | `/bin/bash` 3.2; Homebrew Bash |
| `windows-2025` | Git Bash | Bundled current Bash |
| `windows-2025` | MSYS2 | Current MSYS Bash |
| `windows-2025` | Cygwin | Current Cygwin Bash |

The Bash 3.2 entries fail if the interpreter is not actually version 3.2.
`tests/ci.sh` also puts that interpreter first on PATH for bare `bash` calls
and env-based shebangs. The harness and junction smoke pass the same interpreter
to child invocations. A newer Bash in compatibility mode is not a substitute.
Windows entries use their current native binaries. Bash 3.2 coverage is Unix-only;
both `tests/build-bash32.sh` and `tests/ci.sh 3.2` reject Windows hosts.

The build helper downloads the
[GNU Bash 3.2.57 release](https://ftp.gnu.org/gnu/bash/bash-3.2.57.tar.gz),
verifies its pinned SHA-256, builds in a new private directory and copies
the interpreter into that directory's `bin`. GCC with C development headers,
Make, Bison (and its M4 dependency), curl, tar/gzip and sha256sum are
development/CI tools only. Bison regenerates Bash's parser; it is not needed
by `jvm` or by the offline tests.
The build runs serially because the old readline/history makefiles share object
files unsafely under parallel make, and uses `-fcommon` for tentative definitions
predating GCC 10. The helper is for Unix builds only.
Nothing replaces the system shell or adds a runtime installation step.
The macOS harness needs `sha256sum` for constructing fixture metadata; CI exposes
only Homebrew's checksum binary under that name, retaining native BSD tar, mv
and other system utilities for portability checks.

Equivalent local commands, with the interpreter to test:

```bash
bash tests/ci.sh current
/path/to/bash-3.2 tests/ci.sh 3.2
# Optional private build on Linux with the build tools already available:
bash tests/build-bash32.sh /path/to/new-build-directory
/path/to/new-build-directory/bin/bash tests/ci.sh 3.2
```

All ordinary jobs use fixture downloads. The manual workflow's `real_jdk`
boolean additionally enables `tests/jdk-smoke.sh` for each matrix entry.
No secrets are needed; repository permissions are read-only and checkout
credentials are not persisted. Failed matrix entries do not cancel the others.

CI configuration sources checked on 2026-11-02: the
[runner documentation](https://docs.github.com/en/actions/how-tos/write-workflows/choose-where-workflows-run/choose-the-runner-for-a-job),
[macOS image inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md),
[MSYS2 setup action](https://github.com/msys2/setup-msys2) and
[Cygwin install action](https://github.com/cygwin/cygwin-install-action).
The workflow pins actions to immutable Git object IDs. The
[hosted run for `53b9eaf`](https://github.com/codejive/jvm/actions/runs/41547286511)
passed both Ubuntu jobs and PowerShell 5.1, but failed both macOS jobs and all
four Windows Bash jobs. The fixture and CI repairs above were prepared from
those logs; that historical run does not validate the repairs. Historical
verification notes below describe the checks performed at those dates.

The dangling-reference fixtures create a native directory symlink while its
temporary target exists, then remove that target. This preserves the same
broken-link cases on older MSYS2 runtimes that cannot create a link directly
to a missing target. Fixture setup failures now stop those checks explicitly.

Local verification on 2026-11-02: `tests/ci.sh` passed all 56 discovery checks,
34 installation groups and home/env checks under actual Bash 3.2.57 and
current Bash 5.3.9 on Ubuntu 26.04/WSL2 with glibc. The private build helper
also completed from scratch with GCC 15. `bash tests/ci.sh current` passed the full offline suite
and native junction smoke under Git Bash 5.3.15 and standalone MSYS2 Bash 5.3.9.
`actionlint` 1.7.11 and `git diff --check` passed. These runs use inert fixtures;
the optional real-JDK smoke was not rerun for the CI changes. Native macOS and
Cygwin, including Cygwin's Bash 3.2 build, remain unverified locally.

Configuration defaults (2026-11-02): `bash tests/install.sh --config` covers
independent project/global Java and distro inheritance, explicit selectors,
full IDs and ranges, selectorless install/`-d`, selectorless home/env/exec,
aliases, installed defaults versus major 25, broken references,
configured misses, local ambiguity and operational failures without installation.
It also checks literal parsing, duplicate/unknown/empty/invalid settings,
nonregular/unreadable configuration paths, missing files, lower-priority lazy
reads, XDG fallback and native drive-path conversion when available, paths with
spaces, and current-directory-only lookup. Unaffected queries/help and both
conflicting and malformed configuration around `default` are covered.
The existing `--defaults` lifecycle group now runs with malformed project and
global configuration throughout. The native Windows smoke additionally checks
configured bare-major junction output, selectorless selection using the global
default, and configured exec using the physical home.

Verification on 2026-11-02: Bash syntax validation passed for `jvm` and every
`tests/*.sh` script. The focused `--config` (five groups), `--flags`,
`--defaults`, and home/env suites passed under native Git Bash 5.3.15 on Windows.
The final `bash tests/run.sh` passed all 56 discovery checks, 34 installation
checks (including the five configuration groups), and the home/env suite.
`git diff --check` passed after the final documentation update.
The native Windows junction smoke passed with real `mklink /J`, native executable
traversal and path conversion in isolated storage. ShellCheck was unavailable.
The distributed script measures 66,698 bytes and has LF line endings. Bash 3.2
and native Linux, macOS, Cygwin and standalone MSYS2 remain unverified. Fixture
launchers and copied Windows executables do not establish real-JDK execution.

Index base migration (2026-11-02): `BASE` now uses `https://getjvm.dev/index`.
Bash syntax validation and `bash tests/run.sh --discovery` passed all 56 checks,
including both simulated transfer adapters and a full-origin endpoint assertion.
`bash tests/live-smoke.sh temurin-21` passed under native Windows Git Bash with
curl, returning `21.0.13+9-temurin` twice (initial fetch and fresh cache reuse).
Direct HTTPS checks retrieved the new OpenAPI URL and Windows/Linux x86_64
all-release latest TSVs through HTTP 302 redirects to the original index host,
followed by HTTP 200, preserving the 15-column contract. No JDK artifact was
downloaded or executed. Native wget was unavailable. Historical research links
in SPEC.md retain their original locations. The current script is 66,884 bytes;
`git diff --check` passed. The full installation suite was not rerun for this
base-URL change; the native platform gaps above remain unchanged.

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
and retain its stable link path in output; absent references fall back to
inventory selection and physical homes. The home/env suite covers
missing, unrelated, dangling and wrong-major references, legacy majors and
ambiguity without a major default. The `--flags` checks cover offline
selection with and without a major link, ambiguity without networking, and
returning the exact installed ID after installation races.

Smart env coverage (2026-11-01): `tests/home-env.sh` checks omission of the
PATH export for exact entries at the beginning, middle and end of PATH,
including empty surrounding entries and paths with spaces and shell
metacharacters. It verifies evaluated JAVA_HOME and unchanged PATH order,
rejects substring/trailing-slash matches, and covers alias `e`, selectors and
`-f` in different argument orders, repeated/unsupported flags and simulated
Windows POSIX PATH comparison. The focused suite, Bash syntax checks and full
`bash tests/run.sh` passed under native Git Bash (56 discovery checks, 18
installation checks and the home/env suite). Script size: 51,953 bytes. Native platform and Bash 3.2
verification gaps above are unchanged; ShellCheck was unavailable.

GraalVM env coverage (2026-11-01): `tests/home-env.sh` checks GRAALVM_HOME
for `jvm_impl=graalvm`, independently of distro naming, through exact IDs,
distro-major selectors and global/per-major references. It evaluates exports
with shell metacharacters in paths, omitted PATH output, alias `e`,
`-f`, and simulated Windows native-path conversion. Other JVM types and
missing/invalid manifests preserve an inherited GRAALVM_HOME value. Syntax
checks, the focused suite and `bash tests/run.sh` passed under native Git Bash
5.3.15 (56 discovery checks, 22 installation checks and the home/env suite).
Windows path conversion is simulated, and the platform gaps above remain.
ShellCheck was unavailable. Distributed script size: 58,036 bytes.

Command execution (2026-11-01):
`bash tests/install.sh --execution` checks aliases, usage validation without
utilities, installed selection and ambiguity without networking, automatic
installation, installation failure, staging cleanup before execution, inherited
umask, physical homes after default-link changes, literal arguments (including
empty strings and newlines), child streams/status, missing/unexecutable commands,
process replacement, rejection of the removed `shell`/`s` commands, and simulated
Windows path conversion. Payloads are inert Bash scripts; these checks do not
execute a real JDK. The original implementation passed syntax validation, the
focused checks and `bash tests/run.sh` under native Git Bash (56 discovery
checks, 19 installation checks and the home/env suite) before shell removal.
After removal, Bash syntax checks, `bash tests/run.sh --help-only` and
`bash tests/install.sh --execution` passed under native Git Bash; the full suite
was not rerun. Script size: 53,499 bytes.
Optional exec selector (2026-11-01): execution checks also cover the full usage
diagnostic, no-selector execution through the global default for both `exec`
and `x`, child status propagation, missing/dangling/unrelated defaults, retaining
the physical home when the global reference changes, simulated Windows default
conversion, and selectorless installation fallback. The focused execution checks,
help checks, `bash tests/home-env.sh` and Bash syntax validation passed under native Git Bash. Script
size: 53,685 bytes.
Native Linux/macOS/Cygwin/standalone MSYS2, Bash 3.2 and real-JDK
execution remain unverified; ShellCheck was unavailable.

Version ranges (2026-11-02): `bash tests/install.sh --ranges` covers open and
inclusive major bounds, equal bounds, malformed/reversed bounds, hyphenated
distros, legacy versions and differing vendor/Java versions. It checks listing
order, highest-major selection, remote ties independent of row order, installation
distro filtering, archive preference and duplicate-artifact rejection. Local
checks cover eligible per-major defaults, C-order fallback for absent/dangling/
wrong-major/unrelated defaults, distro-incompatible defaults, physical home/env
and exec output, default major mismatch, exact range-shaped directory names,
uninstall exclusion, operational link-read failures without installation, and
offline-first selection followed by installation on a genuine local miss. The full
suite includes these checks. The optional native Windows smoke also checks
`home`/`env` for `21+` and `21..25` through actual junctions. Payloads remain
inert fixtures, not real JDKs.

Verification on 2026-11-02: Bash syntax validation, focused range checks,
`bash tests/run.sh` (56 discovery checks, 26 installation groups and home/env),
and `bash tests/default-native-windows.sh` passed under native Git Bash 5.3.15.
`git diff --check` passed. Distributed script size: 61,730 bytes. ShellCheck
was unavailable. Bash 3.2, native Linux/macOS/Cygwin/standalone MSYS2 and real-JDK
execution remain unverified; simulated host cases do not establish native support.

All-release discovery and opt-in TYPE (2026-11-02): `bash tests/install.sh --types` checks `available -t`
with GA/EA and empty/nonempty features, comma order, blank GA TYPE cells, header
and tab alignment, first-row deduplication, selectors and alias `a`. It verifies
one shared all-release cache with and without `-t`, selector cache reuse, flag validation,
GA/EA installation eligibility, and unchanged installed/ambiguity columns. The discovery
suite additionally checks that ordinary output includes EA without TYPE and that feature
order survives ID deduplication under `-t`.

Verification on 2026-11-02: Bash syntax checks, `bash tests/run.sh --discovery`
(all 56 checks), `bash tests/install.sh --types` and `git diff --check` passed
under native Git Bash 5.3.15. Script size: 62,215 bytes. The full installation,
home/env and native junction suites were not rerun for this discovery/cache change. Platform/Bash 3.2 gaps above remain; ShellCheck was unavailable.

EA installation and selection (2026-11-02): `bash tests/install.sh --ea` checks
EA manifest preservation/validation, ordinary multi-ID ambiguity, exact and
major/distro/range selection offline, per-major/global defaults, replacement
and removal, physical exec homes, and installation on demand through
home/env/default/exec. A mixed GA/EA range selects the highest eligible major.
Bash syntax checks, the two focused EA groups, `--types`, `--manifest` and
`git diff --check` passed under native Git Bash 5.3.15. Script size: 62,243 bytes.
These checks use inert archives, not real Java runtimes. The full offline suite
was not rerun for this change; Bash 3.2 and other native-platform gaps remain.

Full verification after EA support (2026-11-02): Bash syntax validation,
`bash tests/run.sh` (56 discovery checks, 29 installation groups and home/env),
and `bash tests/default-native-windows.sh` all passed under native Git Bash
5.3.15. This supersedes the partial verification notes above. These runs use
isolated fixture inventories, not real JDK downloads. Other native platforms,
Bash 3.2 and real-JDK execution remain unverified.

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

### Optional real JDK smoke test

```bash
bash tests/jdk-smoke.sh
# Or choose a supported installation selector on this host:
bash tests/jdk-smoke.sh temurin-25
```

This separately invoked test downloads and executes a real JDK; it is never
called by `tests/run.sh`. The default selector is `temurin-21`. It needs network
access for metadata/artifact downloads, enough temporary disk space for the
archive and extracted JDK, and the ordinary host utilities required by `jvm`.
An unavailable or ambiguous selector fails rather than choosing another JDK.
No preinstalled Java or compiler is needed.

The test creates private HOME/XDG roots and a project directory with spaces,
ignores the contributor's configuration, clears inherited Java-specific settings,
and cleans its temporary storage on completion or interruption. It checks the
installed manifest and first-install default, then removes the metadata cache
and blocks curl/wget for all remaining operations, failing if either is called.
It verifies listing and exact-ID reinstall, runs `java -version` and
`javac -version` through `jvm exec`, compiles and executes a tiny Java program,
and checks that the runtime belongs to the selected JAVA_HOME and receives an
argument containing spaces. Finally it uninstalls the JDK and checks empty
inventory, removed defaults/staging, and absence of metadata cache recreation.
It never changes the contributor's JDK inventory, defaults or shell profiles.

Verification on 2026-11-02: `bash tests/jdk-smoke.sh` passed on native Windows
Git Bash 5.3.15 with downloaded Temurin `21.0.13+9-temurin`, including real
compilation/runtime execution through the selected environment and uninstall.
Bash syntax validation passed for `jvm` and the new script. This establishes
real-JDK execution for that host/JDK combination; Bash 3.2, native Linux, macOS,
Cygwin and standalone MSYS2 remain unverified. Earlier fixture-only verification
notes above are historical. ShellCheck was unavailable. The distributed `jvm`
script is unchanged.

On Windows PowerShell, use a real Bash executable, for example:

```powershell
& 'C:\Program Files\Git\bin\bash.exe' -n ./jvm
& 'C:\Program Files\Git\bin\bash.exe' tests/run.sh
& 'C:\Program Files\Git\bin\bash.exe' tests/install.sh
& 'C:\Program Files\Git\bin\bash.exe' tests/live-smoke.sh
& 'C:\Program Files\Git\bin\bash.exe' tests/jdk-smoke.sh
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
`version-source.tsv` exercises version-based IDs and deduplication with the
conditional Java-major prefix, including modern and legacy notation. Major
filters and the unchanged `VERSION` column use `java_version`. Installation checks also verify this display
in remote/local ambiguity tables and offline lists after cache deletion.

Java-major correction coverage (2026-11-01): the installation suite exercises
`22.3.1+java19` with Java 19, a vendor version beginning with `190` for Java 19,
and a version already prefixed with `19-`. It checks discovery, bare-major
installation, durable manifest identity, offline list/home/env/exec/default
selection, major mismatch rejection, and global/per-major replacement on
uninstall. Legacy vendor versions beginning with `1.8` receive an `8-` prefix;
modern vendor versions already beginning with their Java major keep their IDs.
Fixtures retain distinct Java and vendor versions without assigning every JDK
the same artificial Java major.

Verification for this correction: all 56 discovery checks passed through
`bash tests/run.sh`; after updating old installation-fixture expectations,
`bash tests/install.sh` passed all 22 checks and `bash tests/home-env.sh` passed
under native Git Bash 5.3.15. `bash tests/default-native-windows.sh` passed the
isolated junction smoke check. Bash syntax checks for the script and test
harnesses, LF/shebang review and `git diff --check` passed. Script size: 57,838
bytes. Bash 3.2 and native Linux/macOS/Cygwin/standalone MSYS2 checks remain
unverified; ShellCheck was unavailable. No real JDK download/execution was tested.

VERSION display verification (2026-11-01): Bash syntax checks and the full
`bash tests/run.sh` passed under native Git Bash (56 discovery checks, 19
installation checks and the home/env suite). `git diff --check` passed.
The distributed script was 53,707 bytes at that verification. The then-current
manifest v3 added `java_version` for offline display; it was superseded by the
three-line format below. Older manifest formats are not read or migrated. Native
platform and Bash 3.2 verification gaps above remain; ShellCheck was unavailable.

Manifest format checks (2026-11-01): `bash tests/install.sh --manifest` verifies
`jvm-manifest-v1` with exactly three lines, byte-for-byte preservation of the
selected artifact's original TSV row (including CRLF, empty cells, escaped text,
uppercase checksum and appended unknown columns), and offline reading with
additional local columns. The selected row is checked against the preferred
archive variant. The third line starts empty and accepts future local columns.
Invalid markers, truncated/extra lines and incomplete source rows are shown
as `(manifest invalid)` when the launchers remain usable. The ordinary suite runs
these checks too. The fixture manifests in home/env and native Windows checks
use the same format. The append-only product contracts and field definitions
are recorded in [SPEC.md](../SPEC.md#manifest).

Verification on 2026-11-01: Bash syntax checks, 56 offline discovery checks,
the focused manifest and publication suites, home/env checks and the native
Windows junction smoke check passed under Git Bash. The publication suite also
checks flags, aliases and command execution. The script was 54,153 bytes
at that verification.
Bash 3.2, Linux, macOS, Cygwin and standalone MSYS2 native verification remain
outstanding; ShellCheck was unavailable.

Local directory inventory checks (2026-11-01): `bash tests/install.sh --inventory`
covers missing/invalid manifests, diagnostic rows without guessed metadata,
`invalid JDK` precedence for missing launchers, exact-ID home/env/exec/default
selection and offline reuse, exclusion from short selectors, names with spaces,
hidden directories, reserved aliases and non-directory entries. It checks
exact-ID removal without launchers, default replacement without target metadata,
major-reference cleanup and restoring a working manifestless default after a
failed move. The general installation suite includes these checks. The manifest
and publication checks also expect existing directories to remain visible when
metadata or launchers are missing.

Directory-inventory verification on 2026-11-01: Bash syntax checks and the full
`bash tests/run.sh` passed under Git Bash (56 discovery checks, 21 installation
groups and home/env checks). Focused inventory, manifest and default checks
also passed, as did `bash tests/default-native-windows.sh`.
`git diff --check` passed. Distributed script size: 57,140 bytes. Bash 3.2,
Linux, macOS, Cygwin and standalone MSYS2 native verification remain outstanding;
ShellCheck was unavailable. Simulated hosts do not establish native support.

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
archive-provided manifests. Current `jvm-manifest-v1` manifests have an empty
third line, reserved for future local columns; the home is the ID directory.
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

The optional native Windows smoke also exercises `i -d`, `d <ID>`, `h <ID>` and
`e <ID>`, with real junctions and native/Bash path conversion. Its copied
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
