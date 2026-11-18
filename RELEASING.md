# Releasing

## Versioning

Versions follow [Semantic Versioning](https://semver.org) as plain
`X.Y.Z`, tagged `vX.Y.Z`. While the major version is 0, bump the minor
version for new features or behaviour changes and the patch version for
fixes only.

The version lives in one place, `PackageVersion.string` in
[`Sources/SendmailCore/Version.swift`](Sources/SendmailCore/Version.swift).
`--version` prints it, and `flake.nix` reads the package version from it.

## Cutting a release

The `prepare` and `tag` commands need a logged-in `gh` and never switch
or modify your checkout. Add `--dry-run` to either one to see what it
would do without pushing or publishing anything.

1. **Prepare.** From a clean checkout:

   ```sh
   nix run .#release -- prepare X.Y.Z
   ```

   This checks that `X.Y.Z` is greater than both the version on
   `origin/master` and the highest `v*` tag, and that neither the tag
   nor the `release/vX.Y.Z` branch exists. In a temporary worktree it
   branches `release/vX.Y.Z` from `origin/master`, bumps `Version.swift`,
   runs `nix flake check -L`, commits `Release vX.Y.Z`, pushes, and opens
   a PR labelled `release` whose body previews the release notes.

2. **Run the live end-to-end suite** against the release candidate, in
   the Tart VM (see [Live end-to-end tests](#live-end-to-end-tests)).
   From a checkout of the release branch:

   ```sh
   git fetch origin
   git switch --detach origin/release/vX.Y.Z
   nix run .#e2e-vm
   ```

   All 12 scenarios must pass.

3. **Review and merge** the PR once CI passes.

4. **Tag.**

   ```sh
   nix run .#release -- tag X.Y.Z
   ```

   This checks that `Version.swift` on `origin/master` is `X.Y.Z` and that
   the tag doesn't exist locally or on origin, then finds the merged
   release PR's merge commit and checks that it is on `origin/master`.
   It creates the annotated tag `vX.Y.Z` on that commit, pushes it, and
   creates the GitHub release with generated notes. If your local
   `release/vX.Y.Z` branch is fully merged, it deletes it.

Release notes are generated from the merged PRs' labels and grouped by
[`.github/release.yml`](.github/release.yml): `bug` under Fixes,
`enhancement` under Features, `documentation` under Documentation,
`cleanup` under Maintenance, and everything else under Other changes.
Label every PR so it lands in the right section. The `release/` branch
prefix and the `release` label are reserved for release PRs, which the
notes leave out.

Releases carry no binaries: the Nix-built binary links `/nix/store`
libraries and is not portable. Consumers pin the flake to a tag:

```sh
nix run github:thanegill/apple-mail-sendmail/vX.Y.Z -- --version
```

```nix
inputs.apple-mail-sendmail.url = "github:thanegill/apple-mail-sendmail/vX.Y.Z";
```

## Live end-to-end tests

CI runs `nix flake check`, but not the live suite: the suite drives
Mail.app, and the binary's HTML path needs Accessibility, which a
GitHub-hosted runner cannot grant. The live suite
runs locally, in a disposable Tart VM cloned from a prepared golden
image ([`tests/e2e/README.md`](tests/e2e/README.md), "Running it in a
Tart VM"):

- **Before every release**, run the full suite, `nix run .#e2e-vm` (all
  12 scenarios), against the release candidate (step 2 above).
- **After a macOS or Mail update**, rebuild or refresh the golden VM
  image with `nix run .#e2e-vm -- --setup-golden`, so the suite runs
  against the Mail that users have. To rebuild from scratch, delete the
  old golden VM and its marker first, as that README shows.

## If tagging fails

`tag` prints which step failed.

- **Before the tag was pushed:** fix the cause and re-run
  `nix run .#release -- tag X.Y.Z`. If the push itself failed, the
  script has already deleted the local tag.
- **Tag pushed, release not created:** re-running refuses the existing
  tag, so create the release by hand:

  ```sh
  gh release create vX.Y.Z --verify-tag --generate-notes --title vX.Y.Z
  ```

- **No merged release PR** (for example, the version bump landed some
  other way): tag the commit that set the version by hand, after
  checking it.

  ```sh
  git fetch origin --tags
  sha=<commit on origin/master whose Version.swift is X.Y.Z>
  git show "$sha:Sources/SendmailCore/Version.swift"   # must say X.Y.Z
  git tag --annotate vX.Y.Z -m "apple-mail-sendmail vX.Y.Z" "$sha"
  git push origin refs/tags/vX.Y.Z
  gh release create vX.Y.Z --verify-tag --generate-notes --title vX.Y.Z
  ```
