# Publishing the installers

This repository contains publication workflows; no release, deployment or remote
setting is created by building or running the offline tests. Version `0.2.0` is
the initial reviewed pointer in `web/latest.txt`; no tags existed locally or on
origin when inspected on 2026-11-04. The installer defaults from
[INSTALLER_PLAN.md](INSTALLER_PLAN.md) were approved for this implementation.

## Maintainer sequence

1. Review and merge the implementation onto the default branch. Require the
   Bash portability checks to pass: Linux/macOS Bash 3.2/current, Windows Git
   Bash/MSYS2/Cygwin, Windows PowerShell 5.1, shell startup and packaging checks.
   The initial automatic Pages preflight will refuse deployment until the
   release exists. Do not bypass this check or publish a placeholder pointer.
2. In repository Settings → Pages, select **GitHub Actions** as the build source.
   Verify the `github-pages` environment permits only the default branch and
   configure any required reviewers. Ensure Actions policy permits the pinned
   actions and the release job's `contents: write` permission. These are
   maintainer actions; the workflows do not change repository settings.
3. Confirm the two runtime version constants and `web/latest.txt` are `0.2.0`.
   Tag the reviewed commit `v0.2.0` and push that tag. Do not reuse an existing
   version. For later versions, update both constants, and regenerate the
   embedded installer only if `web/install.ps1` changed. A version is exactly
   three numeric components with no leading zeros, except the component `0`.
4. Dispatch **Publish versioned tool** with `tag=v0.2.0` from the reviewed
   default-branch workflow. It checks out and tests that tag, validates the
   version constants and `web/latest.txt`, builds `jvm.tar.gz`,
   `jvm.tar.gz.sha256`, `latest.txt`, then creates a draft with all assets and
   publishes it. Existing releases are never overwritten. If upload fails,
   inspect/delete the incomplete draft before
   retrying; never edit assets of an already published version.
5. After all three public release assets exist, dispatch **Publish installer
   site** on the current default branch. For later releases, update
   `web/latest.txt` alongside the runtime version constants before tagging;
   packaging requires it to match the release version with one final LF.
   The current Pages workflow still reads the pointer and installers from the
   default branch; switching those files to the latest release is pending.
   The preflight verifies the release pointer, archive checksum and contents before
   uploading the allowlisted public files. A queued old revision cannot deploy
   over a newer default-branch revision. If an unrelated commit makes a run
   stale, dispatch a fresh run at the current default-branch head.
6. Verify the existing custom-domain/proxy configuration rather than replacing
   it. The user reported GitHub Pages behind Cloudflare on 2026-11-03; at that
   time `/` returned 404 and the concrete metadata route redirected upstream.
   Preserve the Cloudflare `/index/metadata/...` routing and existing DNS/custom
   domain settings. No CNAME is introduced by this change: the correct Pages
   origin hostname depends on the existing proxy configuration.
7. After deployment, download `/install.sh`, `/install.ps1`, `/latest.txt` and
   the referenced release checksums/payloads over HTTPS, verify exact bytes,
   and review `/` plus an actual
   `/index/metadata/all/linux/x86_64/jdk-latest.tsv` redirect. Installer URLs are
   at the site root, **without `/web/`**. Test the README bootstrap commands
   in disposable homes before announcing availability.

After review/merge and the settings check, the first-release commands are:

```sh
# Replace REVIEWED_COMMIT with the tested, merged commit containing these files.
git tag v0.2.0 REVIEWED_COMMIT
git push origin refs/tags/v0.2.0
gh workflow run release.yml --repo codejive/jvm --ref main -f tag=v0.2.0
# Wait for that run to succeed and verify all three assets are publicly available.
gh workflow run pages.yml --repo codejive/jvm --ref main
```

`main` was the remote default branch when inspected on 2026-11-04. If it changes,
use the new default branch. The commands above are maintainer instructions;
they have not been executed as part of implementation.

## Offline preparation

```sh
python tests/release-tooling.py
python tools/package-release.py 0.2.0 /absolute/new/assets
python tools/package-release.py 0.2.0 /absolute/new/site --site
```

These commands do not publish anything. Destination directories must not exist.
The archive contains `jvm`, `jvm.ps1`, `jvm.cmd` and `latest.txt` at its root,
preserving their exact bytes. Its `latest.txt` matches the standalone asset and
`web/latest.txt`. Its checksum file contains just the SHA-256 digest and a final LF.
Both installers require these archive assets; older releases containing only
individual script assets cannot be installed by the new installers.
The Bash and PowerShell installers are independent entry points. Run their
respective offline suites after editing them; there is no embedding step.

The site staging allowlist is `install.sh`, `install.ps1`, `latest.txt`,
`index.html`, `.nojekyll`; no source tree, test fixtures or site generator is
uploaded. The Pages preflight is intentionally online and is separate from the
offline suite. Release checksums use the same HTTPS trust channel as payloads;
there is no independent signature verification or automatic updater.

Action documentation consulted on 2026-11-04:
[custom Pages workflows](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages),
[upload-pages-artifact](https://github.com/actions/upload-pages-artifact),
[deploy-pages](https://github.com/actions/deploy-pages).
