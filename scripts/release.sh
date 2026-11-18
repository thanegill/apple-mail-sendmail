usage() {
  cat <<'EOF'
Usage:
  nix run .#release -- prepare X.Y.Z [--dry-run]
  nix run .#release -- tag X.Y.Z [--dry-run]

prepare  Open the release PR for vX.Y.Z: branch release/vX.Y.Z from
         origin/master in a temporary worktree, set PackageVersion.string in
         Sources/SendmailCore/Version.swift, run `nix flake check -L`, commit
         "Release vX.Y.Z", push the branch and open a PR labelled `release`.
         Your checkout is never switched or modified.

tag      After that PR has merged: tag its merge commit with the annotated
         tag vX.Y.Z, push the tag, and create the GitHub release with
         generated notes. Deletes the local release/vX.Y.Z branch if it is
         fully merged into origin/master.

  --dry-run  prepare: stop after the local commit, print what would be pushed
             and opened, then delete the worktree and branch.
             tag: print the tag, push and release that would be made, and
             change nothing.
EOF
}

die() {
  echo "release: error: $*" >&2
  exit 1
}

base_branch=master
version_file=Sources/SendmailCore/Version.swift
version_line_regex='^( *public static let string = ")([0-9]+\.[0-9]+\.[0-9]+)"$'
semver_regex='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'

command=""
new_version=""
dry_run=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=true ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*) die "unknown option: $arg (see --help)" ;;
    *)
      if [[ -z "$command" ]]; then
        command="$arg"
      elif [[ -z "$new_version" ]]; then
        new_version="$arg"
      else
        die "unexpected argument '$arg' (see --help)"
      fi
      ;;
  esac
done
case "$command" in
  prepare | tag) ;;
  "")
    usage >&2
    exit 64
    ;;
  *)
    if [[ "$command" =~ ^v?[0-9] ]]; then
      die "missing command; did you mean: nix run .#release -- prepare $command"
    fi
    die "unknown command '$command'; expected 'prepare' or 'tag' (see --help)"
    ;;
esac
[[ -n "$new_version" ]] || die "$command needs a version: nix run .#release -- $command X.Y.Z"
[[ "$new_version" =~ $semver_regex ]] ||
  die "version must be plain semver X.Y.Z (no 'v' prefix, no pre-release or build suffix, no leading zeros), got '$new_version'"

tag="v$new_version"
release_branch="release/$tag"

version_greater() {
  [[ "$1" != "$2" ]] && [[ "$(printf '%s\n' "$1" "$2" | sort -V | tail -n 1)" == "$1" ]]
}

version_at() {
  local version_source
  version_source="$(git show "$1:$version_file" 2>/dev/null)" || die "$1 has no $version_file"
  sed -nE "s/$version_line_regex/\2/p" <<<"$version_source"
}

local_tag_exists() {
  git rev-parse --quiet --verify "refs/tags/$tag" >/dev/null
}

origin_ref_exists() {
  local status=0
  git ls-remote --exit-code "$1" origin "$2" >/dev/null || status=$?
  case "$status" in
    0) return 0 ;;
    2) return 1 ;;
    *) die "could not query origin for $2 (git ls-remote exited $status)" ;;
  esac
}

release_notes() {
  local target="$1" previous_tag_args=()
  [[ -z "$highest_tag" ]] || previous_tag_args=(-f "previous_tag_name=$highest_tag")
  gh api "repos/{owner}/{repo}/releases/generate-notes" \
    -f "tag_name=$tag" -f "target_commitish=$target" "${previous_tag_args[@]}" --jq .body ||
    die "could not generate the release notes preview"
}

gh auth status >/dev/null 2>&1 || die "the GitHub CLI is not logged in (see 'gh auth status'; run 'gh auth login')"

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "run this from inside the apple-mail-sendmail checkout"
cd "$repo_root"

echo "release: fetching origin"
git fetch --quiet origin --tags || die "git fetch origin --tags failed"

highest_tag="$(git tag --list 'v*' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n 1 || true)"

prepare() {
  [[ -z "$(git status --porcelain)" ]] ||
    die "the working tree is not clean; commit or remove these first:"$'\n'"$(git status --short)"

  local current_version
  current_version="$(version_at "origin/$base_branch")"
  [[ -n "$current_version" ]] || die "could not read PackageVersion.string from origin/$base_branch:$version_file"
  version_greater "$new_version" "$current_version" ||
    die "$new_version is not greater than the current version $current_version on origin/$base_branch"
  if [[ -n "$highest_tag" ]]; then
    version_greater "$new_version" "${highest_tag#v}" ||
      die "$new_version is not greater than the highest existing tag $highest_tag"
  fi

  ! local_tag_exists || die "tag $tag already exists"
  ! origin_ref_exists --heads "refs/heads/$release_branch" || die "branch $release_branch already exists on origin"
  ! git rev-parse --quiet --verify "refs/heads/$release_branch" >/dev/null ||
    die "local branch $release_branch already exists; delete it first (git branch -D $release_branch)"

  temp_root="$(mktemp -d "${TMPDIR:-/tmp}/apple-mail-sendmail-release.XXXXXX")"
  worktree_dir="$temp_root/worktree"
  branch_pushed=false
  trap cleanup_prepare EXIT
  trap 'exit 130' INT TERM

  echo "release: creating $release_branch from origin/$base_branch in $worktree_dir"
  git worktree add --quiet --no-track -b "$release_branch" "$worktree_dir" "origin/$base_branch"
  cd "$worktree_dir"

  sed -i -E "s/$version_line_regex/\1$new_version\"/" "$version_file"
  [[ "$(sed -nE "s/$version_line_regex/\2/p" "$version_file")" == "$new_version" ]] ||
    die "failed to set the version in $version_file"

  echo "release: running nix flake check -L"
  nix flake check -L || die "nix flake check failed; nothing was pushed"

  git commit --quiet -m "Release $tag" -- "$version_file"

  local notes pr_title pr_body_file
  notes="$(release_notes "$base_branch")"
  pr_title="Release $tag"
  pr_body_file="$temp_root/pr-body.md"
  cat >"$pr_body_file" <<EOF
Sets \`PackageVersion.string\` to \`$new_version\`.

After this merges, \`nix run .#release -- tag $new_version\` tags the merge commit \`$tag\` and publishes the GitHub release with generated notes.

## Release notes preview

$notes
EOF

  if [[ "$dry_run" == true ]]; then
    echo
    echo "release: dry run; the local commit was:"
    git show --stat HEAD
    echo
    echo "release: would run: git push -u origin $release_branch"
    echo "release: would create the 'release' label if it is missing"
    echo "release: would run: gh pr create --base $base_branch --head $release_branch --label release --title '$pr_title' --body-file <body below>"
    echo "----- PR body -----"
    cat "$pr_body_file"
    echo "-------------------"
    echo "release: dry run complete; removing the worktree and local branch, nothing was pushed"
    return 0
  fi

  if ! gh label list --limit 500 --json name --jq '.[].name' | grep -qx release; then
    gh label create release --color 5319e7 --description "Release PR opened by nix run .#release"
  fi

  git push -u origin "$release_branch"
  branch_pushed=true

  gh pr create --base "$base_branch" --head "$release_branch" --label release \
    --title "$pr_title" --body-file "$pr_body_file" ||
    die "$release_branch was pushed but opening the PR failed; open it with: gh pr create --base $base_branch --head $release_branch --label release --title '$pr_title'"
  echo "release: after the PR merges, run: nix run .#release -- tag $new_version"
}

cleanup_prepare() {
  cd "$repo_root"
  if [[ -d "$worktree_dir" ]]; then
    git worktree remove --force "$worktree_dir" || echo "release: warning: could not remove worktree $worktree_dir" >&2
  fi
  rm -rf "$temp_root"
  if [[ "$branch_pushed" == false ]] && git rev-parse --quiet --verify "refs/heads/$release_branch" >/dev/null; then
    git branch --quiet -D "$release_branch" || echo "release: warning: could not delete local branch $release_branch" >&2
  fi
}

tag_release() {
  local master_version
  master_version="$(version_at "origin/$base_branch")"
  [[ "$master_version" == "$new_version" ]] ||
    die "Version.swift on origin/$base_branch is '$master_version', not $new_version; merge the release PR first (nix run .#release -- prepare $new_version opens it)"

  ! local_tag_exists || die "tag $tag already exists locally"
  ! origin_ref_exists --tags "refs/tags/$tag" || die "tag $tag already exists on origin"

  local manual_hint="to tag by hand, see 'If tagging fails' in RELEASING.md"
  local merged_prs pr_number merge_sha
  merged_prs="$(gh pr list --state merged --head "$release_branch" --json mergeCommit,number \
    --jq '.[] | "\(.number) \(.mergeCommit.oid)"')" ||
    die "could not list merged PRs for $release_branch"
  [[ -n "$merged_prs" ]] || die "no merged PR from $release_branch; $manual_hint"
  [[ "$(wc -l <<<"$merged_prs")" -eq 1 ]] ||
    die "more than one merged PR from $release_branch (number and merge commit):"$'\n'"$merged_prs"$'\n'"$manual_hint"
  read -r pr_number merge_sha <<<"$merged_prs"
  [[ "$merge_sha" =~ ^[0-9a-f]{40}$ ]] || die "PR #$pr_number has no merge commit; $manual_hint"

  local ancestor_status=0
  git merge-base --is-ancestor "$merge_sha" "origin/$base_branch" 2>/dev/null || ancestor_status=$?
  case "$ancestor_status" in
    0) ;;
    1) die "PR #$pr_number's merge commit $merge_sha is not on origin/$base_branch" ;;
    *) die "PR #$pr_number's merge commit $merge_sha is not in this repository after fetching origin" ;;
  esac
  [[ "$(version_at "$merge_sha")" == "$new_version" ]] ||
    die "Version.swift at PR #$pr_number's merge commit $merge_sha is not $new_version"

  echo "release: PR #$pr_number merged $release_branch as $merge_sha"

  local branch_merged=false
  if git rev-parse --quiet --verify "refs/heads/$release_branch" >/dev/null &&
    git merge-base --is-ancestor "refs/heads/$release_branch" "origin/$base_branch"; then
    branch_merged=true
  fi

  if [[ "$dry_run" == true ]]; then
    echo "release: would run: git tag --annotate $tag -m 'apple-mail-sendmail $tag' $merge_sha"
    echo "release: would run: git push origin refs/tags/$tag"
    echo "release: would run: gh release create $tag --verify-tag --generate-notes --title $tag"
    if [[ "$branch_merged" == true ]]; then
      echo "release: would delete the local branch $release_branch (fully merged into origin/$base_branch)"
    fi
    echo "----- release notes preview -----"
    release_notes "$merge_sha"
    echo "---------------------------------"
    echo "release: dry run complete; nothing was tagged, pushed or released"
    return 0
  fi

  git tag --annotate "$tag" -m "apple-mail-sendmail $tag" "$merge_sha"
  if ! git push origin "refs/tags/$tag"; then
    git tag --delete "$tag" >/dev/null
    die "pushing $tag failed; the local tag was deleted, so this command can be re-run"
  fi
  echo "release: pushed $tag ($merge_sha)"

  gh release create "$tag" --verify-tag --generate-notes --title "$tag" ||
    die "$tag is pushed but creating the release failed; run: gh release create $tag --verify-tag --generate-notes --title $tag"

  if [[ "$branch_merged" == true ]]; then
    if git branch --quiet -D "$release_branch"; then
      echo "release: deleted the local branch $release_branch (fully merged into origin/$base_branch)"
    else
      echo "release: warning: could not delete the local branch $release_branch" >&2
    fi
  fi
}

case "$command" in
  prepare) prepare ;;
  tag) tag_release ;;
esac
