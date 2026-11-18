# Releasing

## Versioning

Versions follow [Semantic Versioning](https://semver.org) as plain
`X.Y.Z`, tagged `vX.Y.Z`. While the major version is 0, bump the minor
version for new features or behaviour changes and the patch version for
fixes only.

The version lives only in `PackageVersion.string` in
[`Sources/SendmailCore/Version.swift`](Sources/SendmailCore/Version.swift).

## Cutting a release

`prepare` and `tag` need a logged-in `gh` and never switch or modify
your checkout. Add `--dry-run` to either to see what it would do
without pushing or publishing anything.

1. **Prepare**, from a clean checkout:

   ```sh
   nix run .#release -- prepare X.Y.Z
   ```

   In a temporary worktree this bumps `Version.swift` on a
   `release/vX.Y.Z` branch from `origin/master`, runs
   `nix flake check -L`, pushes, and opens a PR labelled `release`
   whose body previews the release notes.

2. **Run the live end-to-end suite** on the release candidate, in the
   Tart VM (see [Live end-to-end tests](#live-end-to-end-tests)):

   ```sh
   git fetch origin
   git switch --detach origin/release/vX.Y.Z
   nix run .#e2e-vm
   ```

   All 12 scenarios must pass.

3. **Review and merge** the PR once CI passes.

4. **Tag:**

   ```sh
   nix run .#release -- tag X.Y.Z
   ```

   This tags the merged release PR's merge commit `vX.Y.Z`, pushes the
   tag, and creates the GitHub release with generated notes.

Release notes are grouped by the merged PRs' labels
([`.github/release.yml`](.github/release.yml)), so label every PR. The
`release/` branch prefix and the `release` label are reserved for
release PRs, which the notes leave out.

Releases carry no binaries: the Nix-built binary links `/nix/store`
libraries and is not portable. Consumers pin the flake to a tag:

```nix
inputs.apple-mail-sendmail.url = "github:thanegill/apple-mail-sendmail/vX.Y.Z";
```

## Live end-to-end tests

CI cannot run the live suite: it drives Mail.app, and the HTML path
needs Accessibility, which a GitHub-hosted runner cannot grant. It runs
locally in a disposable Tart VM cloned from a prepared golden image
([`tests/e2e/README.md`](tests/e2e/README.md#running-it-in-a-tart-vm)):

- **Before every release**, run `nix run .#e2e-vm` (all 12 scenarios)
  against the release candidate (step 2 above).
- **After a macOS or Mail update**, rebuild or refresh the golden VM
  with `nix run .#e2e-vm -- --setup-golden`, so the suite runs against
  the Mail that users have. To rebuild from scratch, delete the old
  golden VM and its marker first, as that README shows.

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
  other way): check and tag the commit that set the version by hand.

  ```sh
  git fetch origin --tags
  sha=<commit on origin/master whose Version.swift is X.Y.Z>
  git show "$sha:Sources/SendmailCore/Version.swift"   # must say X.Y.Z
  git tag --annotate vX.Y.Z -m "apple-mail-sendmail vX.Y.Z" "$sha"
  git push origin refs/tags/vX.Y.Z
  gh release create vX.Y.Z --verify-tag --generate-notes --title vX.Y.Z
  ```
