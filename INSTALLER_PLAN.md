# Installer implementation handoff

Date: 2026-11-03. Implementation: 2026-11-04, approved defaults applied.
The installer sources, tests and publication workflows are implemented locally;
publication and hosted verification remain maintainer steps in RELEASING.md.
SPEC.md records completed behavior and recovery boundaries.
Read `AGENTS.md` and `SPEC.md` before implementation. This document defines the
work breakdown; `SPEC.md` remains the product contract. When implementing,
update the contract to distinguish completed behavior from remaining proposals.

## Objective and boundaries

Deliver user-wide installers at `https://getjvm.dev/install.sh` and
`https://getjvm.dev/install.ps1`. Install the tool into the resolved user's
`~/.local/bin`, offer persistent PATH setup, and separately offer persistent
JAVA_HOME/default-JDK PATH setup. Keep JDK storage under the existing XDG roots.

User decisions already established:

- The installer is essential. `jvm use` is independent, optional and excluded.
- Executable placement is `~/.local/bin`, independent of XDG_DATA_HOME, on all
  platforms. Windows uses native paths beneath the same home-resolution policy
  as `jvm.ps1` (HOME, then USERPROFILE when HOME is unavailable).
- Offer tool PATH setup when needed and default-JDK environment setup separately.
- Windows persists these settings in the current user's environment registry.
- Put public installer sources and optional website content in root-level
  `web/`. Deploy its contents as the Pages site root through GitHub Actions.
- The domain now reaches GitHub Pages through Cloudflare. On 2026-11-03 the
  root returned 404, but a concrete `/index/metadata/...` URL still redirected
  to the existing upstream index. Do not change that metadata routing.

Do not implement `use`, change `env`, create shell functions for dispatch,
clear GRAALVM_HOME, install a JDK, set a persistent JDK default, edit project
copies, add runtime dependencies, or add automatic updates. No new JDK-manager
command is necessary. A landing page is optional and must not delay installers.

## Proposed defaults for this plan

These defaults originally filled gaps in the discussion. The user approved
them on 2026-11-04 for this implementation. The remaining text preserves the
implementation handoff; SPEC.md describes the resulting contract, and
RELEASING.md records publication steps and verification boundaries.

1. Publish versioned GitHub Release assets; default to a stable version recorded
   in a small Pages `latest.txt`. Support explicit version selection. Never fetch
   tool payloads from the moving default branch or scrape JSON/HTML for versions.
2. Ship `jvm` on Unix and all three scripts (`jvm`, `jvm.ps1`, `jvm.cmd`) on
   Windows, regardless of which installer is used. Require no Bash installation
   for the native PowerShell route.
3. Support persistent setup for Bash, Zsh, Fish, csh and tcsh, plus Windows user
   environment values. Unknown/custom shells get manual instructions. Unix
   shell setup is not a prerequisite for installing the executable.
4. Rerunning an installer updates an installation it owns; matching installed
   content is a no-op. Refuse unrelated or locally modified destination files
   with an actionable explanation. No overwrite/force flag in version one.
5. Permit default-JDK setup before a default exists, explaining that Java becomes
   available after the first JDK installation. Do not resolve it through `home`
   or `env`, since those commands can install JDKs.
6. Document manual tool removal initially. Do not add an uninstall command.

## Public installer interface

Proposed Bash options:

```text
install.sh [--version <version>]
           [--path | --no-path] [--java | --no-java]
           [--shell bash|zsh|fish|csh|tcsh] [--profile <absolute-path>]
           [--non-interactive]
install.sh --help
```

Proposed PowerShell equivalents: `-Version`, `-Path` / `-NoPath`, `-Java` /
`-NoJava`, `-NonInteractive`, and `-Help`. Shell/profile options are Unix-only;
the native installer is Windows-only. Reject conflicting or unsupported options
before networking, directory creation or edits. Help requires no network.

Defaults and consent:

- Installing/updating the tool is the requested action and needs no extra prompt.
- Ask separately about missing tool PATH setup and default-JDK setup; show the
  exact target files/registry values and intended changes. Default answers are no.
- Detect an already-correct managed setup and avoid repeat prompts and edits.
- Explicit positive options consent to their respective edits. Negative options
  suppress them. Never silently replace an unrelated JAVA_HOME without showing
  the old/new value interactively or receiving explicit `--java` / `-Java`.
- With no terminal or in noninteractive mode, install the tool and skip unspecified
  environment edits, printing manual instructions. Explicit positive options still
  work unattended; unresolved custom profile selection fails that requested step.
- Read Bash prompts from `/dev/tty`, not piped script stdin. PowerShell must detect
  inability to prompt and follow the same noninteractive policy.
- `--shell` selects one shell per invocation. Detection may suggest the login
  shell, but the interpreter running install.sh is not proof of caller shell.
  Do not edit every installed shell automatically.
- `--profile` explicitly selects a startup file for the chosen shell. Reject it
  without a shell selection. Unknown shell detection skips automatic setup with
  instructions rather than guessing a profile.

Examples to document once implemented:

```sh
curl -fsSL https://getjvm.dev/install.sh | bash
curl -fsSL https://getjvm.dev/install.sh | bash -s -- --path --no-java --non-interactive
```

```powershell
iex (irm 'https://getjvm.dev/install.ps1')
# For options, download to a file and invoke that script with parameters.
```

CMD can launch the PowerShell installer with `powershell.exe -NoProfile -Command`.
Test exact quoting of the documented invocation. Do not change machine execution
policy. Use the existing Windows PowerShell 5.1 baseline and built-in .NET.

Exit statuses: 0 for completed installation with requested setup successful (or
optional setup declined), 2 for invalid arguments, 1 for operational failure.
If requested environment setup fails after successful tool publication, return 1
and explicitly report that the tool was installed and which setup step failed.

## Step 1: Distribution and publication contract

Add release packaging outside the runtime scripts, with an offline validation
mode. Proposed tag convention: `v<version>`, with `<version>` a documented strict
numeric dotted version. First inspect existing tags and version constants; do
not rename existing releases or publish a release without authorization.

For each release, produce exact-byte assets:

```text
jvm
jvm.ps1
jvm.cmd
SHA256SUMS
```

The checksum file has one SHA-256 digest and one allowlisted basename per line.
Use a fixed small parser. Reject duplicate/missing entries, invalid digests,
unexpected paths and HTML/error responses. Hash the downloaded bytes before
setting permissions or publishing. Do not execute downloaded scripts to discover
their versions or verify their identity.

Proposed URLs:

```text
https://getjvm.dev/latest.txt
https://github.com/codejive/jvm/releases/download/v<VERSION>/<ASSET>
```

Read latest.txt once, validate its single version value, then pin every payload
request to that version. Explicit versions bypass latest.txt. HTTPS redirects
must be followed with failures checked; reuse the project's capability approach
for curl/wget, SHA-256 alternatives and Windows .NET TLS support. No archive
extraction, jq or GitHub API parsing is required.

Checksums fetched through the same HTTPS release channel detect inconsistent or
corrupted downloads; they do not authenticate against a compromised publisher.
The bootstrap script itself is trusted through HTTPS. Do not claim independent
signature verification. Signing is outside this initial proposal.

Add release and Pages workflows using least required permissions, pinned actions
following repository practice, and the GitHub Pages deployment environment.
Consult current official action documentation when implementing.

- Release publication builds assets from a checked, explicit tag/revision and
  runs the relevant tests. Do not overwrite assets of a published version.
- Maintain reviewed `web/latest.txt`; its version advances only after the release
  assets exist. A Pages preflight verifies the referenced release is complete.
- Deploy Pages on default-branch changes to `web/` or the Pages workflow, plus
  manual dispatch. Gate deployment on installer checks for that same revision.
- Upload only a staging copy of `web/`, not the repository. Run no site generator
  for installer scripts. Exclude contributor/test files and preserve script bytes.
- Concurrent deployments must not let an older queued run replace newer content.
- Account for the domain's actual custom-domain/proxy configuration. Do not assume
  a visible HTTP redirect or change Cloudflare/DNS during repository work.
- Explain the first-release bootstrap sequence: release assets first, then the
  corresponding latest.txt and Pages deployment. Do not publish a broken pointer.

## Step 2: Installer transaction and ownership

Implement `web/install.sh` and `web/install.ps1` as standalone files. Keep helpers
readable and separated by concern. No runtime helper downloads except the
version/checksum/payload data. Preserve LF in Bash and the project script bytes.

Suggested ownership state: `$XDG_DATA_HOME/jvm/tool-install/` with the existing
data-home fallback and absolute-path rules. This is NEW proposed storage; add
its exact schema and lifecycle to SPEC when implementing. Store installed version,
destination and hashes for owned filenames as literal data. Do not source it.

Algorithm:

1. Validate arguments, host, home, roots and required capabilities.
2. Resolve/pin version, stage downloads in a private temporary directory, and
   verify the complete selected payload. Nothing edits profiles or registry yet.
3. Before publication, serialize installer mutations with a small installer-only
   lock in the ownership directory; recheck destination state under that lock.
   This does not introduce a lock for JDK installation or inventory operations.
   A concurrent invocation can fail clearly and be retried; no busy waiting needed.
4. Treat symlinks/reparse points, directories and unowned existing destination
   files as conflicts. Detect locally modified owned scripts using saved hashes.
5. Stage replacement files on the destination filesystem and preserve old owned
   versions plus a literal transaction record before renaming anything.
6. Publish the complete payload and ownership record with checked operations.
   On failure or a catchable interruption, restore the old payload. A Windows
   multi-file replacement is not atomic: record that limitation honestly.
   The next invocation must recognize interrupted publication and recover before
   proceeding; never delete recovery material blindly or guess at a stale lock.
7. Apply consented environment setup after successful publication. Back up each
   changed profile or registry value first and restore that step on failure.
   Do not roll back a usable tool installation merely because setup failed.
8. Clean only owned staging, report installed version/path, and explain how to
   open a refreshed terminal or apply the displayed setup instructions.

A process killed between file renames can leave a temporary mixed installation
until recovery. Do not promise atomic multi-file visibility or power-loss durability.
Keep the recovery design small; do not add a version-switching launcher framework.

## Step 3: Unix persistent setup

Generate native shell syntax containing resolved literal paths, properly quoted.
Never evaluate user metadata or an existing profile. No JDK commands, network
requests or inventory scans at shell startup. The tool bin and default-JDK bin
are separate whole PATH entries; add only if absent. Preserve existing entries.
JAVA_HOME names the stable default reference, including on macOS bundle layouts
as defined by the existing reference contract. No GRAALVM_HOME setup is needed.

Use separate marked blocks for tool PATH and default Java, so reruns can enable
one without duplicating or removing the other. Preserve surrounding content,
encoding/line endings where practical, permissions and an exact backup. Stop
on duplicate/corrupt markers. Do not replace a symlinked profile with a regular
file: resolve and show its target or require an explicit target override.

Shell policies:

- Bash: update `.bashrc` and the active readable login file from `.bash_profile`,
  `.bash_login`, `.profile`. If none exists, propose `.profile`. Never create a
  higher-priority login file that hides an existing one. Idempotent checks allow
  both files to run without duplicate entries. Keep `.profile` content POSIX.
- Zsh: use `.zshrc` beneath known ZDOTDIR or HOME. ZDOTDIR can be set in startup
  code and not exported; show the assumed path and allow an explicit override.
- Fish: use a dedicated user `conf.d/jvm.fish` under XDG_CONFIG_HOME (fallback
  `.config`). Treat an unowned existing file as a conflict. Use exported variables
  and the shell's list PATH semantics, not POSIX shell statements.
- Csh/tcsh: use `.cshrc`, or existing `.tcshrc` for tcsh with `.cshrc` fallback.
  Implement native `setenv`/`path` handling, including unset variables. Test it
  in actual shells in hosted CI; do not substitute string-only assertions.

Check both the current PATH and managed startup configuration: current membership
does not establish persistence. When ambiguous, explain that it is present now
and offer persistent setup rather than silently claiming it is installed there.
Later user startup statements can override managed values; document this boundary.
Profile setup does not configure every GUI application or noninteractive process.

## Step 4: Windows persistent setup

PowerShell owns registry updates. When install.sh runs under Git Bash/MSYS2/Cygwin,
use native path conversion and delegate consented registry setup to the verified
PowerShell installer without recursion, duplicate download/publication or duplicate
prompts. Design a private, validated setup-only invocation if necessary; document
it as internal and do not expose an arbitrary command-evaluation interface.
If this introduces unnecessary complexity, share a private staged-data contract,
not duplicated registry mutation code in Bash. Test the selected design end to end.

Use `HKCU\Environment`, not machine values. Read raw values without expansion;
preserve existing REG_SZ/REG_EXPAND_SZ types and unrelated PATH tokens. Never
persist the process's merged PATH. Use semicolon entry parsing and appropriate
case/path comparison; preserve original spelling of untouched entries. Do not
use setx. Add concrete native absolute paths without quotes inside PATH entries.
Notify applications of environment changes after successful writes.

Tool PATH setup adds `.local\bin`. Java setup sets JAVA_HOME to the existing
resolved data root's `jvm\jdks\default` and adds its `bin` path. Preview both
changes together. Handle a missing PATH value and an existing unrelated JAVA_HOME.
User PATH membership cannot guarantee precedence over a system Java entry;
report observed shadowing without modifying machine PATH or deleting other tools.

Persisted edits do not refresh existing terminals/IDEs. Do not promise that a
new tab in an old host inherits fresh values. No PowerShell profiles are needed
for this milestone. Keep Bash-specific conversion instructions available if a
Windows shell startup file subsequently overrides the inherited PATH.

## Step 5: Verification and acceptance

Add `tests/tool-installer.sh` and `tests/tool-installer.ps1` (names deliberately
distinct from existing JDK installation tests). Extend `tests/ci.sh`, the hosted
matrix and `tests/README.md` with actual runnable commands when created.

Every test uses temporary HOME/XDG/destination/profile locations and fake
downloaders or local fixture services. Registry operations need an injectable
backend/key for tests; never exercise the developer's real HKCU environment.
Verify exact raw types/values using disposable keys where native registry tests
are needed, and clean only those keys. No CI test installs a real JDK.

Acceptance cases:

- Help and invalid/conflicting options have no side effects; piped bootstrap
  prompts never consume script bytes. Interactive and unattended choices agree.
- Latest and pinned versions, HTTPS redirects, downloader alternatives, HTTP
  errors, malformed version/checksum data, missing files and checksum mismatch.
- Fresh install, matching reinstall, update, locally modified/unowned conflicts,
  two concurrent installers, publication failures and interrupted-run recovery.
- Paths containing spaces and supported shell metacharacters, native Windows
  paths, non-ASCII homes, XDG overrides and invalid/relative home overrides.
  Reject unrepresentable PATH separator/newline paths clearly before mutation.
- Each consent combination; existing tool PATH; missing default JDK; existing
  JAVA_HOME; no duplicate PATH entries; no JDK storage/default mutation.
- Correct Bash login precedence, custom ZDOTDIR/profile override, Fish config
  roots, csh/tcsh unset variables, profile backups and symlink handling.
- A real fresh shell loads generated setup in hosted tests; no startup download,
  accidental output or command evaluation occurs. Shell text is not merely
  compared against private helper output.
- Windows registry value preservation, expandable references, missing PATH,
  setup failures/rollback and repeated invocation through PowerShell and Bash.
- Launcher payload bytes remain mutually consistent; ordinary existing `jvm`
  commands and project-local copies retain behavior.
- Pages artifact contains only intended public files, installer URLs have no
  `/web/` prefix, and latest.txt references available verified release assets.

Use hosted Linux/macOS Bash 3.2/current and current Git Bash/MSYS2/Cygwin plus
Windows PowerShell 5.1. Add hosted Zsh/Fish/csh/tcsh setup checks. Observe AGENTS.md:
do not install alternative shells, run WSL/containers or broaden local platform
validation without express confirmation. Report native gaps rather than claiming
simulations prove support. Run syntax checks, relevant existing regressions,
ShellCheck if available, and `git diff --check`; measure shipped script sizes.

After authorized deployment, separately smoke-check public bootstrap downloads,
checksums, landing-page response if included, and an actual `/index/metadata/...`
redirect. Live checks are optional deployment validation, not default tests.

## Step 6: Documentation and delivery

Update SPEC's commands/current behavior only when implementation exists. Add
installer interfaces, ownership storage, failure/recovery rules, supported shell
setup and Windows boundaries. Update the manual-only setup statement to distinguish
the installer from ordinary manager commands. Keep `use` deferred.

Update README with interactive and unattended installation examples, first JDK
installation, terminal refresh, repeat-install updates, pinned versions, and
manual tool removal. Removal instructions must identify only installer-owned
files/blocks/registry entries, preserve JDKs/config/cache, and avoid restoring
old environment values over subsequent user edits. Keep project-copy instructions.

Suggested reviewable implementation sequence:

1. Versioned payload/checksum contract, packaging fixtures and installer core.
2. Unix persistent setup and shell tests.
3. Windows persistent setup and Bash-on-Windows integration tests.
4. Release/Pages workflows and documentation, then authorized publication.

Deliver code and tests, a list of checks actually run, remaining platform gaps,
and concrete repository/Pages settings needed by the maintainer. Do not create
commits, releases, change remote settings or deploy as a side effect of local
implementation unless separately authorized. Do not start work on `use`.
