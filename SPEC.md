# jvm specification

## Status and purpose

`jvm` is a small command line tool for obtaining and selecting Java Development
Kits (JDKs). Projects commit a copy of the tool and invoke it directly; users do
not need to install a separate JDK manager. JDK downloads and user preferences
are shared across those project copies.

This document distinguishes implemented discovery behavior from requirements for
later milestones. Requirements expressed as MUST are mandatory for their stated
scope. Details marked **proposed** remain design choices for review.

### First implementation milestone (authorized 2026-10-29)

Implemented in the single Bash file `jvm`: `help`, `--help`, `--version`, and
`available [selector]`; host and libc detection; validated XDG cache paths;
GA latest TSV fetching through curl or wget; discovery across JVM implementations;
trusted TSV reading; compatible archive filtering; ID construction and selector
filtering; and a one-hour metadata cache with conditional requests and silent fallback.
The current version is 0.1.0. Listings preserve upstream order and return all
matching IDs; this milestone does not choose the highest version or an artifact
for installation. Each matching ID displays once. Duplicate IDs are collapsed
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
interval. Only the four discovery entry points above are implemented. The
installation, managed local listing, persistent default, archive extraction,
checksum verification and durable installed-manifest requirements below remain
future work. Session switching, command execution and general JSON parsing are
excluded. Help does not advertise deferred commands as working.

See [tests/README.md](tests/README.md) for exact verification commands and gaps.

## Scope

The eventual installation-capable initial version MUST (only discovery is
implemented in this milestone):

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

Initial scope does not require uninstall, system-wide installation, automatic
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

The names and exit codes are adopted. `help`, `--help`, `--version`, and
`available` are implemented; `list`, `install`, and `default` are deferred.
The following commands describe the intended complete interface.

```text
jvm help
jvm --help
jvm --version
jvm available [selector]
jvm list [selector]
jvm install <selector>
jvm default [selector]
```

- `available` lists compatible JDKs across JVM implementations from the API's
  latest index, covering the latest release of every major across distributions. No argument,
  a major, a distro, and a distro-major all use that same index and cache.
  Historical versions are outside the current discovery interface.
- `list` lists complete managed installations; no network access is allowed.
  Empty results are a successful empty list.
- `install` resolves a remote selector and installs that exact artifact. It is
  idempotent for an already complete installation and MUST NOT change the default.
- `default` without an argument reports the current selection, or explicitly
  reports that none exists. With an argument it selects an already installed
  JDK; it MUST NOT silently download one.
- `help` shows implemented command usage and a short selector explanation.
  Omit routine implementation details and deferred commands.
- Full IDs MUST be shown untruncated. Discovery does not accept them as selectors;
  exact IDs remain part of the future installed-JDK interface below. Listings
  show `ID`, `DISTRIBUTION`, `VERSION`, and `JVM`. Omit the platform column;
  discovery already filters for the current host.
- Align listing headers and values with tabs at 8-column stops. Size each column
  from the widest displayed value or header, placing the next column at the
  following tab stop, capped at four tab stops (32 columns) per column. Longer
  values remain untruncated and get one separating tab; they may overflow the
  usual alignment without widening the other rows. Preserve row order and apply
  the same layout to redirected output; repeated tabs are display padding.
- Diagnostics and progress go to stderr; command results go to stdout. Avoid
  interactive prompts and terminal-only formatting in redirected output.
- **Adopted:** exit 0 for success (including empty lists and future no default), 2 for
  invalid usage, and 1 for operational failures, no selector match, or ambiguity.

## Identity and selection

### Full IDs

A full ID MUST use `<version>-<distro>` for every JVM implementation. Use the API's
`version` value as supplied for IDs, displayed versions, and major matching;
`java_version` is not used. This adopts the user's manual change, confirmed
on 2026-10-30, and supersedes the earlier Java-version-based identity decision.
`distro` is the canonical distribution identifier. Never append `jvm_impl` to
the ID. This 2026-10-30 user decision prioritizes shorter IDs; collisions across
JVM implementations are accepted for now, with resolution deferred. For example:

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
Collision handling and installation artifact preferences are deferred.

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

### Installed selectors and resolution (future requirements)

- Try an exact full-ID match first.
- A positive integer such as `21` selects that Java major version.
- A selector such as `temurin-21` selects that distribution and Java major.
  Split the major from the final hyphen; distro names can contain hyphens.
- Distribution names use canonical jdkdb-index identifiers.
- `list` returns all selector matches. `install` and `default` must resolve to
  a single artifact or installation. These commands remain unimplemented.
- **Proposed:** for a short selector, choose the highest stable Java version
  within the requested major. Compare numeric version components and build
  numbers, not lexical strings. Handle legacy Java 8 version notation. Use
  `version` for version matching and ordering, consistently with ID construction.
- If several distinct IDs remain at the highest Java version (for example,
  different distributions or JVMs), fail with their full IDs and ask
  the user to supply a full ID. Do not silently prefer a vendor or API row order.
- Unrecognized version ordering must produce an explicit ambiguity/error,
  rather than a guessed ordering. Exact-ID selection remains possible.
- Short selectors are floating choices; print the resolved ID on installation
  and selection. A persistent default stores the exact ID, not the selector.

Remote resolution uses the API's own latest selection for each major version;
the API need not supply an ordering key. Resolve within that inventory, retaining
the ambiguity rules above. Local resolution MUST work offline and still needs
version comparison when several installed versions match a short selector.

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
  A valid installation contains `bin/java` and `bin/javac`, or their `.exe`
  equivalents. Validate version/platform metadata without sourcing vendor files.

## User storage

Use the freedesktop XDG directory conventions on every platform, including
Windows; do not substitute AppData or macOS Library paths.

| Purpose | Location |
| --- | --- |
| Installed JDKs and their manifests | `${XDG_DATA_HOME:-$HOME/.local/share}/jvm/jdks/<id>/` |
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

## Persistent default and shell integration

**Proposed:** the `default` reference is a directory symlink to the selected
normalized JDK home. Users add its `bin` directory to PATH once. Help and a
successful selection show the actual resolved setup paths and equivalent of:

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

On Windows, a fake symlink implemented as a directory copy is unacceptable.
Probe whether the Bash environment can create and traverse a real directory
link to the JDK and launch native `java.exe` through it. If that fails, preserve
the previous default and explain the environment's link/permission requirement.
**Open design issue:** supporting persistent selection without native link
capability may need a directory junction or another mechanism. Do not assume
`ln -s` works everywhere or introduce dynamic shell shims in this milestone.

Default updates must be serialized and preserve a working prior reference on
failure. Use an atomic reference replacement where supported; document and test
any platform-specific interruption window. Never overwrite an unrelated file or
directory at the reference path.

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
warning-only policy. Future artifact-selection decisions remain deferred.

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
- Serialize mutations to shared storage across project copies, using portable
  locking (for example an atomic lock directory). Handle interruptions and stale
  locks explicitly; do not steal a lock merely because it is old.
- Failed/interrupted installation must leave existing JDKs and the default
  usable. Clean up only temporary paths owned by that operation. Partial installs
  must never appear in `list` or resolve as usable JDKs.
- Quote paths and handle spaces and shell metacharacters in HOME, XDG paths,
  project paths, and download data. Do not use `eval` or source manifests, API
  responses, config, or JDK `release` files.
- Use user-owned locations without sudo/admin installation. No telemetry or
  unrelated network traffic is required.

## Acceptance criteria

The later installation-capable initial version is ready when (these are not
claims about the discovery milestone):

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

- Validate floating-version ordering and the installation ambiguity policy
  against real inventory samples; check the required ID scheme for collisions.
- Decide the Windows fallback, if any, when real directory links are unavailable.
- Settle artifact variant preferences; keep general JSON parsing deferred as a
  last resort.
- Record actual platform/architecture coverage; a simulated detection test does
  not establish that native extraction, linking, and Java execution work.


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
- Cache storage alone is used. Only the needed cache XDG root is resolved;
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
- Version ordering, installation artifact preference, Windows default-link
  fallback and installed manifests remain deferred. No general JSON parser exists.
- Verification to date: Bash syntax validation, the deterministic offline suite,
  and native Git Bash 5.3 discovery with curl plus a second cached invocation.
  Other host cases and both downloader adapters are simulated by the suite.
  Bash 3.2 and ShellCheck were not available; Linux, macOS, Cygwin and standalone
  MSYS2 native runs remain unverified. No archive/execution/linking support is
  claimed by discovery checks.
