#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage:
  scripts/mobile-release.sh start X.Y.Z [START_REF]
  scripts/mobile-release.sh candidate X.Y.Z
  scripts/mobile-release.sh finalize X.Y.Z-rc.N

start      Create and push mobile-release/X.Y.Z from START_REF (default: main).
candidate  Tag the release branch tip as the next mobile-vX.Y.Z-rc.N candidate.
finalize   Publish a GitHub Release for an existing tested candidate tag.

Finalization records the tested candidate. It does not create a stable alias tag
or start another build.
USAGE
  exit 2
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

require_clean_semver() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
    fail "'$1' is not a mobile release version (expected X.Y.Z)"
}

require_candidate_version() {
  [[ "$1" =~ ^([0-9]+\.[0-9]+\.[0-9]+)-rc\.([1-9][0-9]*)$ ]] || \
    fail "'$1' is not a mobile candidate version (expected X.Y.Z-rc.N, N >= 1)"
  candidate_version="${BASH_REMATCH[1]}"
}

require_clean_tree() {
  git diff --quiet && git diff --cached --quiet && \
    [[ -z "$(git status --short --untracked-files=normal)" ]] || \
    fail "working tree is dirty; commit or stash changes first"
}

require_annotated_tag() {
  local git_dir="$1" object="$2" label="$3"
  if [[ "$(git -C "$git_dir" cat-file -t "$object" 2>/dev/null || true)" != "tag" ]]; then
    echo "$label must be an annotated tag" >&2
    return 1
  fi
}

remote_tag_commit_sha() {
  local ref="$1" line advertised_oid tmp fetched_oid commit
  line="$(git ls-remote --refs origin "$ref")"
  [[ -n "$line" && "$line" != *$'\n'* ]] || return 1
  advertised_oid="${line%%$'\t'*}"
  tmp="$(mktemp -d)"
  git -C "$tmp" init -q
  git -C "$tmp" remote add origin "$(git remote get-url origin)"
  if ! git -C "$tmp" fetch -q --depth 1 origin "$ref"; then
    rm -rf "$tmp"
    return 1
  fi
  fetched_oid="$(git -C "$tmp" rev-parse --verify FETCH_HEAD)"
  if [[ "$fetched_oid" != "$advertised_oid" ]]; then
    rm -rf "$tmp"
    fail "$ref moved while it was being resolved"
  fi
  if ! require_annotated_tag "$tmp" FETCH_HEAD "$ref"; then
    rm -rf "$tmp"
    return 1
  fi
  if ! commit="$(git -C "$tmp" rev-parse --verify 'FETCH_HEAD^{commit}')"; then
    rm -rf "$tmp"
    return 1
  fi
  rm -rf "$tmp"
  printf '%s' "$commit"
}

remote_branch_commit_sha() {
  local ref="$1" line advertised_oid tmp fetched_oid commit
  line="$(git ls-remote --refs origin "$ref")"
  [[ -n "$line" && "$line" != *$'\n'* ]] || return 1
  advertised_oid="${line%%$'\t'*}"
  tmp="$(mktemp -d)"
  git -C "$tmp" init -q
  git -C "$tmp" remote add origin "$(git remote get-url origin)"
  if ! git -C "$tmp" fetch -q --depth 1 origin "$ref"; then
    rm -rf "$tmp"
    return 1
  fi
  fetched_oid="$(git -C "$tmp" rev-parse --verify FETCH_HEAD)"
  if [[ "$fetched_oid" != "$advertised_oid" ]]; then
    rm -rf "$tmp"
    fail "$ref moved while it was being resolved"
  fi
  if ! commit="$(git -C "$tmp" rev-parse --verify 'FETCH_HEAD^{commit}')"; then
    rm -rf "$tmp"
    return 1
  fi
  rm -rf "$tmp"
  printf '%s' "$commit"
}

command="${1:-}"
case "$command" in
  start)
    [[ "$#" -ge 2 && "$#" -le 3 ]] || usage
    version="$2"
    start_ref="${3:-main}"
    require_clean_semver "$version"
    require_clean_tree
    branch="mobile-release/$version"
    if git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
      fail "origin/$branch already exists"
    fi
    start_sha="$(remote_branch_commit_sha "refs/heads/$start_ref")" || \
      fail "origin/$start_ref does not exist"
    git fetch -q origin "refs/heads/$start_ref"
    fetched_sha="$(git rev-parse --verify 'FETCH_HEAD^{commit}')"
    [[ "$fetched_sha" == "$start_sha" ]] || \
      fail "origin/$start_ref moved while it was being resolved"
    if ! git branch "$branch" "$fetched_sha"; then
      fail "local branch $branch already exists"
    fi
    if ! git push --set-upstream origin "$branch"; then
      git branch -D "$branch" >/dev/null
      fail "could not publish $branch"
    fi
    printf 'Created %s at %s from %s.\n' "$branch" "$start_sha" "$start_ref"
    ;;

  candidate)
    [[ "$#" -eq 2 ]] || usage
    version="$2"
    require_clean_semver "$version"
    require_clean_tree
    branch="mobile-release/$version"
    branch_ref="refs/heads/$branch"
    branch_sha="$(remote_branch_commit_sha "$branch_ref")" || \
      fail "origin/$branch does not exist"

    next=1
    while IFS=$'\t' read -r _ ref; do
      [[ "$ref" =~ ^refs/tags/mobile-v${version//./\.}-rc\.([1-9][0-9]*)$ ]] || continue
      number="${BASH_REMATCH[1]}"
      (( number >= next )) && next=$((number + 1))
    done < <(git ls-remote --refs --tags origin "refs/tags/mobile-v${version}-rc.*")

    tag="mobile-v${version}-rc.${next}"
    git fetch -q origin "$branch_ref"
    fetched_sha="$(git rev-parse --verify 'FETCH_HEAD^{commit}')"
    [[ "$fetched_sha" == "$branch_sha" ]] || \
      fail "origin/$branch moved while it was being resolved"
    git tag -m "Buzz Mobile $version release candidate $next" "$tag" "$fetched_sha"
    if ! git push origin "refs/tags/$tag"; then
      git tag -d "$tag" >/dev/null
      fail "could not publish $tag"
    fi
    git tag -d "$tag" >/dev/null
    printf 'Published %s at %s. Use this exact tag in Release Mobile.\n' \
      "$tag" "$fetched_sha"
    ;;

  finalize)
    [[ "$#" -eq 2 ]] || usage
    candidate="$2"
    require_candidate_version "$candidate"
    tag="mobile-v$candidate"
    branch="mobile-release/$candidate_version"
    tag_sha="$(remote_tag_commit_sha "refs/tags/$tag")" || \
      fail "origin has no exact annotated candidate tag $tag"
    branch_sha="$(remote_branch_commit_sha "refs/heads/$branch")" || \
      fail "origin/$branch does not exist"

    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    git -C "$tmp" init -q
    git -C "$tmp" config user.name "Buzz Mobile Release"
    git -C "$tmp" config user.email "mobile-release@buzz.invalid"
    git -C "$tmp" remote add origin "$(git remote get-url origin)"
    git -C "$tmp" fetch -q --depth 1 origin "refs/tags/$tag"
    fetched_sha="$(git -C "$tmp" rev-parse --verify 'FETCH_HEAD^{commit}')"
    [[ "$fetched_sha" == "$tag_sha" ]] || \
      fail "$tag moved while it was being resolved"
    if ! git -C "$tmp" fetch -q --unshallow origin "refs/heads/$branch"; then
      fail "could not fetch complete history for origin/$branch"
    fi
    fetched_branch_sha="$(git -C "$tmp" rev-parse --verify 'FETCH_HEAD^{commit}')"
    [[ "$fetched_branch_sha" == "$branch_sha" ]] || \
      fail "origin/$branch moved while it was being resolved"
    git -C "$tmp" merge-base --is-ancestor "$tag_sha" "$fetched_branch_sha" || \
      fail "$tag is not reachable from origin/$branch"

    if gh release view "$tag" --repo block/buzz >/dev/null 2>&1; then
      fail "GitHub Release for $tag already exists"
    fi
    notes="$(cat <<NOTES
Final mobile release for marketing version \`$candidate_version\`.

Promoted tested candidate \`$tag\` at \`$tag_sha\`. The mobile stores receive
that candidate's existing signed artifacts. This release records the source
selected for store rollout and must not trigger another application build.
NOTES
)"
    gh release create "$tag" --repo block/buzz --verify-tag \
      --title "Buzz Mobile $candidate_version" \
      --notes "$notes" --latest=false
    ;;

  *) usage ;;
esac
