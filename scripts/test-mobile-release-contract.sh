#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/scripts/mobile-release.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
remote="$tmp/remote.git"
work="$tmp/work"
bin="$tmp/bin"
mkdir -p "$bin"
cat > "$bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
case "$1:$2" in
  release:view)
    printf '%s\n' "$*" >> "$GH_CAPTURE"
    exit 1
    ;;
  release:create) printf '%s\n' "$*" >> "$GH_CAPTURE" ;;
  *) exit 2 ;;
esac
GH
chmod +x "$bin/gh"
export PATH="$bin:$PATH"
git init -q --bare "$remote"
git init -q "$work"
git -C "$work" config user.name test
git -C "$work" config user.email test@example.com
git -C "$work" remote add origin "$remote"
echo first > "$work/file"
git -C "$work" add file
git -C "$work" commit -qm first
git -C "$work" branch -M main
git -C "$work" push -q -u origin main

# Start must work from a stale operator clone by fetching the remotely resolved
# source commit before creating the local release branch.
operator="$tmp/operator"
git clone -q "$remote" "$operator"
git -C "$operator" config user.name test
git -C "$operator" config user.email test@example.com
echo remote-only >> "$work/file"
git -C "$work" commit -qam remote-only
git -C "$work" push -q origin main
remote_main_sha="$(git --git-dir="$remote" rev-parse refs/heads/main)"
if git -C "$operator" cat-file -e "$remote_main_sha^{commit}" 2>/dev/null; then
  echo "stale-clone fixture already contains the remote-only commit" >&2
  exit 1
fi
(
  cd "$operator"
  "$script" start 1.2.3
)
[[ "$(git --git-dir="$remote" rev-parse refs/heads/mobile-release/1.2.3)" == \
   "$remote_main_sha" ]]
git -C "$work" fetch -q origin refs/heads/mobile-release/1.2.3

# Candidate tags always point at the remote release branch, not the operator's
# current checkout, and sequence monotonically without moving an old tag.
echo second >> "$work/file"
git -C "$work" commit -qam second
git -C "$work" push -q origin HEAD:refs/heads/mobile-release/1.2.3
(
  cd "$work"
  "$script" candidate 1.2.3
  "$script" candidate 1.2.3
)
branch_sha="$(git --git-dir="$remote" rev-parse refs/heads/mobile-release/1.2.3)"
[[ "$(git --git-dir="$remote" rev-parse 'refs/tags/mobile-v1.2.3-rc.1^{commit}')" == "$branch_sha" ]]
[[ "$(git --git-dir="$remote" rev-parse 'refs/tags/mobile-v1.2.3-rc.2^{commit}')" == "$branch_sha" ]]

# A selected candidate remains valid after the release branch advances. This is
# the normal finalization shape when later fixes or RCs landed after testing.
echo third >> "$work/file"
git -C "$work" commit -qam third
git -C "$work" push -q origin HEAD:refs/heads/mobile-release/1.2.3
advanced_branch_sha="$(git --git-dir="$remote" rev-parse refs/heads/mobile-release/1.2.3)"
[[ "$advanced_branch_sha" != "$branch_sha" ]]

# A failed branch publication does not strand the local release branch.
failing_operator="$tmp/failing-operator"
git clone -q "$remote" "$failing_operator"
git -C "$failing_operator" config user.name test
git -C "$failing_operator" config user.email test@example.com
cat > "$failing_operator/.git/hooks/pre-push" <<'HOOK'
#!/usr/bin/env bash
exit 1
HOOK
chmod +x "$failing_operator/.git/hooks/pre-push"
if (
  cd "$failing_operator"
  git config core.hooksPath .git/hooks
  "$script" start 9.9.9 >/dev/null 2>&1
); then
  echo "start succeeded despite a rejected push" >&2
  exit 1
fi
if git -C "$failing_operator" show-ref --verify --quiet refs/heads/mobile-release/9.9.9; then
  echo "failed start stranded a local release branch" >&2
  exit 1
fi
if git --git-dir="$remote" show-ref --verify --quiet refs/heads/mobile-release/9.9.9; then
  echo "failed start published a remote release branch" >&2
  exit 1
fi

# The script must verify the existing non-tip tag, record the tested candidate,
# and never create a stable mobile-vX.Y.Z tag.
(
  export GH_CAPTURE="$tmp/gh-call"
  cd "$work"
  "$script" finalize 1.2.3-rc.2
)
grep -Fq 'release view mobile-v1.2.3-rc.2 --repo block/buzz' "$tmp/gh-call"
grep -Fq 'release create mobile-v1.2.3-rc.2 --repo block/buzz --verify-tag' "$tmp/gh-call"
if git --git-dir="$remote" rev-parse --verify refs/tags/mobile-v1.2.3 >/dev/null 2>&1; then
  echo "finalization created a stable alias tag" >&2
  exit 1
fi

# A lightweight candidate tag is rejected. Candidate identity must carry an
# immutable annotated tag object, not only a commit ref.
git -C "$work" -c tag.gpgSign=false tag mobile-v1.2.3-rc.3 main
git -C "$work" push -q origin refs/tags/mobile-v1.2.3-rc.3
if GH_CAPTURE="$tmp/lightweight-gh-call" PATH="$bin:$PATH" \
    "$script" finalize 1.2.3-rc.3 >/dev/null 2>&1; then
  echo "lightweight candidate tag was accepted" >&2
  exit 1
fi

# A candidate outside the matching release branch is rejected at finalization.
git -C "$work" tag -m "unrelated candidate" mobile-v1.2.3-rc.4 main
git -C "$work" push -q origin refs/tags/mobile-v1.2.3-rc.4
if GH_CAPTURE="$tmp/bad-gh-call" PATH="$bin:$PATH" \
    "$script" finalize 1.2.3-rc.4 >/dev/null 2>&1; then
  echo "unrelated candidate tag was accepted" >&2
  exit 1
fi

grep -Fq 'version: 0.0.0+1' "$repo_root/mobile/pubspec.yaml"
if grep -qE 'release-mobile|bump-mobile-version|get-current-mobile-version' "$repo_root/Justfile"; then
  echo "metadata-only mobile release recipe remains in Justfile" >&2
  exit 1
fi

echo "mobile release contract passed"
