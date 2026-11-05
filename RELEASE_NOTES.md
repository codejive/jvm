# v0.2.1

Prepared release notes; publication is pending.

Changes since v0.2.0:

- Fix Windows CMD `env` output so its comment and environment assignments can
  be copied and pasted, preserving the existing PATH through `%PATH%`.
- Include the MIT license notice in each runtime script and standalone
  installer so it travels with redistributed copies.
- Offer local project installation alongside user installation in both
  installers. Improve setup prompts and show the appropriate next command for
  existing JDK installations.
- Refresh the installation website with copyable commands and Duke artwork,
  and expand the README's installation and usage guidance.
- Simplify Pages publication to publish the current website files directly,
  independently of runtime releases.

The standalone installers and website are published separately from the
versioned runtime scripts. Release assets remain `jvm.tar.gz`,
`jvm.tar.gz.sha256` and `latest.txt`.
