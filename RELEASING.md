# Releasing jvm

## Requirements

- Git and GitHub CLI (`gh`), authenticated with permission to push tags and run
  workflows in `codejive/jvm`.
- A new `major.minor.patch` version, with no leading zeros. Never reuse a
  published version or replace its assets.
- GitHub Actions enabled, including permission for the release workflow to
  create releases.
- For Pages: select **GitHub Actions** in Settings → Pages and allow deployment
  from the default branch in the `github-pages` environment.

## Release process

Replace `VERSION`, `REVIEWED_COMMIT` and `DEFAULT_BRANCH` in the commands below.

1. Set the same version in `jvm` (`VERSION`), `jvm.ps1` (`$script:Version`) and
   `web/latest.txt`. The text file must end with one LF. Update the PowerShell
   HTTP User-Agent, version-output test and pinned README examples to agree.
   Prepare [release notes](RELEASE_NOTES.md) describing changes since the previous
   tag. Commit and review the changes before tagging.
2. Tag the reviewed commit and push the tag:

   ```sh
   git tag vVERSION REVIEWED_COMMIT
   git push origin refs/tags/vVERSION
   ```

3. Start the release workflow:

   ```sh
   gh workflow run release.yml --repo codejive/jvm --ref DEFAULT_BRANCH -f tag=vVERSION
   ```

4. Wait for the workflow to pass and the release to be published. Confirm that
   it contains `jvm.tar.gz`, `jvm.tar.gz.sha256` and `latest.txt`. If publication
   fails, inspect and remove any incomplete draft before retrying.
5. Merge the reviewed changes into the default branch. Changes to `web/`
   automatically publish Pages. To publish manually:

   ```sh
   gh workflow run pages.yml --repo codejive/jvm --ref DEFAULT_BRANCH
   ```

6. Confirm `https://getjvm.dev/latest.txt` shows the released version and that
   `/install.sh` and `/install.ps1` are available. Test the README installation
   commands in a disposable home before announcing the release.
