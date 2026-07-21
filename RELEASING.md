# Releasing Buzz

Buzz has three independent release lanes. Desktop and relay use release PRs;
mobile uses a release branch plus immutable candidate tags:

| Lane | Entry point | Artifact |
|------|-------------|----------|
| Desktop | `just release-desktop` | Signed desktop app (macOS/Linux) |
| Relay | `just release-relay` | `ghcr.io/block/buzz` container image |
| Mobile | `scripts/mobile-release.sh` | Buzz mobile app |

The lanes version independently. Desktop reads its manifests, relay reads its
crate manifest, and mobile derives both source and marketing version from the
exact candidate tag. The mobile handoff to the private `buzz-releases` pipeline
remains manual because OSS CI cannot trigger private CI.

## Quick Start

```sh
# Desktop release (next patch version)
just release-desktop

# Desktop explicit version
just release-desktop 0.4.0

# Relay release
just release-relay
just release-relay 0.4.0

# Start mobile stabilization from remote main
scripts/mobile-release.sh start 0.5.0

# Publish each tested candidate from the remote release-branch tip
scripts/mobile-release.sh candidate 0.5.0

# After store rollout selects a tested candidate, record that exact RC
scripts/mobile-release.sh finalize 0.5.0-rc.2
```

Desktop and relay releases use metadata PRs. Mobile does not. Its moving
`mobile-release/<version>` branch is the stabilization line, and every
`mobile-v<version>-rc.N` tag is an immutable candidate identity.

---

## How It Works

### Desktop

1. **`just release-desktop`** runs locally on `main`, creates or updates a
   `version-bump/<version>` PR, bumps the desktop manifests, regenerates
   lockfiles, and updates `CHANGELOG.md`.
2. **Merge the PR.** `auto-tag-on-release-pr-merge` pushes `v<version>`.
3. **The tag triggers `release.yml`.** It builds, signs, notarizes, and
   publishes the desktop app for macOS and Linux.

### Relay

1. **`just release-relay`** runs locally on `main`, creates or updates a
   `relay-release/<version>` PR, bumps `crates/buzz-relay/Cargo.toml`,
   regenerates `Cargo.lock`, and updates the relay changelog.
2. **Merge the PR.** `auto-tag-on-release-pr-merge` pushes
   `relay-v<version>`.
3. **The tag triggers `docker.yml`.** Stable releases update the version
   aliases and `latest`; prereleases do not.

Every push to `main` continues to publish the rolling relay `:main` and
`:sha-<7>` tags.

### Mobile

1. **Start a stabilization branch.** From a clean checkout whose `origin` is
   `block/buzz`, run
   `scripts/mobile-release.sh start X.Y.Z`. The script resolves the exact
   remote `main` commit and creates `mobile-release/X.Y.Z` there. Fixes may be
   merged or pushed to this branch while the release is stabilized.
2. **Tag a candidate.** Run `scripts/mobile-release.sh candidate X.Y.Z`. It
   resolves the exact remote release-branch tip and publishes the next
   annotated `mobile-vX.Y.Z-rc.N` tag. Existing candidates are never moved.
3. **Build the exact tag.** Enter that candidate tag as `mobile_ref` in the
   private Buzz mobile Buildkite pipeline. OSS CI deliberately cannot trigger
   that private pipeline. The tag supplies both source commit and release
   version. Flutter receives clean marketing version `X.Y.Z`; Buildkite's
   monotonically increasing build number supplies the platform build number.
4. **Finalize without rebuilding.** Promote the signed artifacts from the
   selected tested RC to the stores, then run
   `scripts/mobile-release.sh finalize X.Y.Z-rc.N`. This verifies that the tag
   is reachable from the matching release branch and publishes a GitHub Release
   on that same RC tag. There is no stable alias tag and no final rebuild.

`mobile/pubspec.yaml` keeps `0.0.0+1` only as a valid, visibly non-release
fallback for local development and validation builds. Release jobs always
inject both version fields. `mobile/CHANGELOG.md` is retained as historical
release data; GitHub Release notes are the release ledger going forward.

---

## Version Sources

| Lane | Release version authority |
|------|---------------------------|
| Desktop | `desktop/package.json` and synchronized desktop manifests |
| Relay | `crates/buzz-relay/Cargo.toml` |
| Mobile | Exact `mobile-vX.Y.Z-rc.N` remote tag |

`just bump-desktop-version <version>` updates the desktop manifests and
regenerates their lockfiles. `just bump-relay-version <version>` updates the
relay crate and regenerates `Cargo.lock`. Mobile has no bump recipe or
release-metadata PR.

---

## Manual Fallback

Desktop supports the manual GitHub Actions fallback:

1. Go to **Actions > Release** in the GitHub UI.
2. Click **Run workflow**.
3. Provide the semver version and the immutable tag ref to build.

Mobile intentionally has no branch or arbitrary-ref fallback. Buildkite accepts
only an exact candidate tag.

---

## Internal Releases

For mobile, trigger the private
[Release Mobile pipeline](https://buildkite.com/runway/buzz-mobile-releases) with
the exact RC tag. For desktop, use
[Release Desktop](https://buildkite.com/runway/sprout-releases). See the
[buzz-releases README](https://github.com/squareup/buzz-releases#cutting-a-release)
for the private pipeline contract.

---

## What Gets Published

Desktop publishes two GitHub releases:

1. **`v<version>`**: the user-facing release with installers.
2. **`buzz-desktop-latest`**: the rolling auto-updater release.

Mobile finalization adds one GitHub Release to the selected
`mobile-v<version>-rc.N` tag. It records which already-tested candidate was
promoted and does not publish or rebuild the store binaries.

---

## Platform Support

The release workflow builds **two separate macOS DMGs**: Apple
Silicon (`darwin-aarch64`, the `release` job) and Intel
(`darwin-x86_64`, the `release-macos-x64` job), plus Linux `.deb` and
`.AppImage`. Both macOS DMGs are codesigned, notarized, and attached to
the same `v<version>` release. Intel users download the `_x64.dmg`.

The Linux AppImage is post-processed by `desktop/scripts/fix-appimage.sh`,
which strips infra libraries over-bundled by linuxdeploy (they crash on
Mesa 25+ / GLib 2.88 distros; see
[tauri-apps/tauri#15665](https://github.com/tauri-apps/tauri/issues/15665))
and re-signs the artifact. As a result the AppImage relies on the
host's Wayland/GStreamer/graphics stack and requires GLib >= 2.72
(Ubuntu 22.04 or newer). The `release-linux` job builds inside a
`ubuntu:22.04` container for broad GLIBC compatibility.

---

## Prerequisites

- **Write access** to the `block/buzz` GitHub repository
- **`gh` CLI** authenticated (`gh auth status`)
- The following **GitHub Actions secrets** must be configured:

  | Secret | Purpose |
  |--------|---------|
  | `BUZZ_UPDATER_PUBLIC_KEY` | Tauri updater public key (minisign) |
  | `TAURI_SIGNING_PRIVATE_KEY` | Tauri updater private key |
  | `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` | Password for the private key |

---

## Troubleshooting

### `just release-desktop` fails with "must be on main branch"
Switch to `main` and pull latest before running the release recipe.

### `just release-desktop` fails with "working tree is dirty"
Commit or stash your changes before running the release recipe.

### New commits after starting mobile stabilization

Land the intended fixes on `mobile-release/<version>`, then run
`scripts/mobile-release.sh candidate <version>` again. It publishes a new
immutable RC tag from the current remote branch tip.

### A mobile candidate command selects the wrong RC number

Do not retry by moving or deleting a tag. Inspect the remote `mobile-v*` tags
and resolve the unexpected state. Candidate numbers are monotonically
increasing remote identities.

### Auto-updater reports "no update available"
Verify that the `buzz-desktop-latest` release exists and contains a
valid `latest.json`. The manifest covers all four platform keys
(`darwin-aarch64`, `darwin-x86_64`, `linux-x86_64`,
`windows-x86_64`); a missing entry usually means that platform's
release job failed. Check the workflow run.
