# Discovery verification

Run from the repository root in Bash (3.2 or later):

```bash
bash -n ./jvm
bash -n tests/run.sh
bash -n tests/live-smoke.sh
bash tests/run.sh
```

The offline suite creates temporary HOME and XDG roots, including paths with
spaces. Its isolated PATH supplies ordinary utility wrappers and fake host,
curl and wget commands. It makes no network calls, downloads no JDKs, and never
reads or writes normal JDK inventories, defaults, or shell profiles. It requires
the ordinary tools used by `jvm`, plus `chmod` to prepare executable fakes.
Temporary files are cleaned on completion or interruption. Runtime code is only
`jvm`; no fixtures or tests need distribution.

Optional development checks, only when installed:

```bash
shellcheck -s bash jvm tests/run.sh tests/live-smoke.sh
/path/to/bash-3.2 -n ./jvm
/path/to/bash-3.2 tests/run.sh
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
& 'C:\Program Files\Git\bin\bash.exe' tests/live-smoke.sh
```

Syntax checks and the offline suite run under Git Bash 5.3.15. Native Git Bash/
curl discovery and cached reuse were verified on 2026-10-29. The offline suite
also checks
brief main/subcommand help, distro/major/distro-major selectors on the same
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
