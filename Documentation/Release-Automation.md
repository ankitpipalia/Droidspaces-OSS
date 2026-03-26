# Release Automation

This repository now ships a dedicated GitHub Actions release pipeline that publishes downloadable assets from the repository that runs it, including forks.

## What It Publishes

When the release workflow runs successfully, it creates or updates a GitHub release in the current repository with:

- a universal Android release APK
- per-architecture backend tarballs for `x86_64`, `aarch64`, `armhf`, and `x86`
- one multi-architecture backend tarball
- `SHA256SUMS.txt` for all release assets

## How To Trigger It

### Option 1: Push a version tag

Push a tag like:

```bash
git tag v5.1.0
git push origin v5.1.0
```

The `Release Packages` workflow will build the release and publish it to the current repository's Releases page.

### Option 2: Run it manually

Open the `Release Packages` workflow in GitHub Actions and run it with:

- `tag_name`: required release tag, for example `v5.1.0`
- `release_name`: optional title override
- `prerelease`: optional prerelease flag
- `draft`: optional draft flag

If the tag does not already exist, GitHub CLI creates the release tag from the workflow commit.

## Fork Behavior

The workflow uses `${{ github.repository }}` at runtime, so:

- upstream builds publish to upstream releases
- your fork builds publish to your fork releases

No workflow edits are required when running it from a fork.
