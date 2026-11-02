# Contributor and agent instructions

## Project contract

Read `SPEC.md` before changing behavior. It is the source of truth for product
requirements, interfaces, storage, platform support, and deferred features.
This file describes how to work on the project. Keep that division intact.

The user authorized discovery on 2026-10-29 and extended the milestone on
2026-10-30 to `install <selector>` and offline `list`, including
verified archive extraction, durable manifests, and atomic publication from
independent temporary directories without a storage lock.
The optional selector for `list [selector]` was restored on 2026-10-30.
Persistent defaults and manual shell setup were authorized on 2026-10-30,
including Windows junctions, first-install selection and replacement on default
uninstallation. JDK command execution was authorized on 2026-11-01. The user
subsequently removed the dedicated `shell`/`s` command while retaining `exec`/`x`.
Broader parent-shell session switching remains deferred.
The native Windows PowerShell 5.1 entry point `jvm.ps1` was requested on
2026-11-02; its documented archive boundaries remain in force.
Uninstallation was authorized on 2026-10-30, with offline
ID/major/distro-major selection and move-before-delete removal through
`jvm/tmp/remove-<ID>.XXXXXXXX`. Do not infer further authorization from the
detailed future requirements in `SPEC.md`.

Discovery trusts the project-owned TSV index. Index/schema validation and build
collision checks belong upstream, not in the discovery command. Keep its reader
small and fast; test filtering, silent ID deduplication, caching and treating
data as data. Keep installation validation separate from this trusted reader.

## Keeping the documents current

- Update `SPEC.md` in the same change as observable behavior, dependency,
  storage, selector, or compatibility changes. Update help/examples to agree.
- Preserve the distinction between user requirements, proposed choices, verified
  upstream behavior, and unresolved decisions. Do not silently promote a proposal
  into a user requirement or claim unimplemented behavior already exists.
- Keep procedures here rather than duplicating them throughout the spec. Put
  durable product decisions in the spec, with rationale where useful.
- When research changes API assumptions, inspect the live OpenAPI definition and
  representative responses. Record the date and source links in `SPEC.md`.
  Suggested endpoints must remain explicitly labeled until actually available.
- Resolve routine implementation choices within authorized scope. Ask for input
  when a choice materially changes scope or a user requirement; present the
  concrete tradeoff and any work already completed.

## Implementation discipline

- Keep the Bash implementation in one file, `jvm`; the requested native
  PowerShell implementation is the separate `jvm.ps1` entry point. Keep fixtures,
  tests, and contributor tooling outside the distributed artifacts. Do not add a
  runtime package installation step.
- Follow the spec's Bash baseline and dependency rules. Avoid newer Bash
  features, GNU-only assumptions, hidden language runtimes, and mandatory `jq`.
- If proposing Java for a feature, first document the guaranteed JDK/preinstall
  path and prove there is no bootstrap cycle. Do not weaken the language rule
  to simplify metadata handling.
- Separate concerns within the file: capability/host detection, HTTP transfer,
  metadata normalization, selection, storage, installation, and CLI dispatch.
  Prefer small readable functions to duplication or compressed shell tricks.
- Keep changes focused. Do not add future session switching, dynamic shims, or
  command execution as incidental work.
- Preserve LF line endings and the Bash shebang. Preserve executable mode when
  version control supports it; keep `bash ./jvm` usable on Windows.
- Treat external metadata and archives as data. Quote expansions, avoid `eval`
  and sourcing data files, validate storage keys, and scope cleanup precisely.
- Maintain readable error messages and check failures explicitly. Account for
  Bash's `set -e`, pipeline, subshell, and trap behavior rather than assuming
  global strict-mode settings make failure handling correct.
- Never run development checks against the contributor's actual JDK inventory,
  default link, shell profile, or normal XDG directories.

## Verification

Choose checks appropriate to the change. Documentation-only changes need link,
example, consistency, and formatting review; do not add implementation tests for
them. Do not claim a command ran or a platform passed unless verified.

When implementation exists:

- Local platform or Bash-version validation that do WSL/container platform runs,
  building or installing alternative shells or that need platform tooling for
  validation require express user confirmation. A request to create or change CI
  does not authorize these local runs. Prefer the configured hosted CI jobs; report
  unverified platforms rather than starting local platform tests without confirmation.
  This restriction does not require confirmation for the configured jobs running in
  hosted CI.
- Run Bash syntax validation (`bash -n ./jvm`) and relevant behavioral tests.
  Use ShellCheck when available as a development tool, not a runtime dependency.
- Use a lightweight Bash test harness and small checked-in metadata fixtures.
  Keep ordinary tests deterministic and offline, with fake transfer commands.
  Separate optional live API/download smoke checks from the default suite.
- Give tests temporary HOME/XDG directories and isolated PATH/capability setups.
  Ensure cleanup cannot escape the test workspace.
- Cover current distro/major/distro-major discovery selectors, legacy and modern
  versions, hyphenated distros, missing matches, and silent duplicate IDs. Add
  installed-ID selection and durable offline manifests when implemented.
- Exercise curl-only and wget-only paths, extractor/checksum alternatives,
  trusted TSV input (including unused empty/escaped fields and unchecked headers),
  version-based IDs (with distinct java_version fixture values),
  explicit archive-format filtering, duplicate artifact rows, HTTP failures,
  conditional 304 handling, cache freshness, silent fallback to valid cache,
  failed initial fetch, checksum mismatch, and archive traversal/link rejection.
  Do not implement a general JSON parser unless simpler API formats prove
  insufficient and that direction is explicitly revisited.
- Test interrupted installation/default replacement and concurrent publication.
  Verify a prior usable installation/default survives failures.
- Cover paths with spaces, XDG overrides, macOS bundle layout, musl/glibc
  distinctions, and Windows native executable/link behavior.
- Check Bash 3.2 and current Bash. Before claiming platform support, run native
  smoke checks on Linux, macOS, Cygwin, MSYS2, and Git Bash where available.
  Use hosted CI or obtain the express confirmation required above for local runs.
  Distinguish simulated platform tests from native verification and report gaps.
- Measure distributed script size after meaningful growth. Prefer meaningful
  regression tests to tests that merely mirror private helper implementation.

Do not invent build commands or CI status before tooling exists. Add documented
test commands alongside the harness when it is introduced.

## Review and reporting

Before completing a change, review its diff for consistency with the spec,
unintended dependencies, portability assumptions, and changes outside scope.
Use `git diff --check` if this workspace is under Git; otherwise inspect the
edited files directly. Do not initialize Git or create commits unless requested.

Report what changed, what was verified, and material unresolved decisions or
platform gaps. Keep implementation progress separate from intended behavior.
Do not describe a documented proposal as a completed feature.
