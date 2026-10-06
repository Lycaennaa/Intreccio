# Setup

This guide covers installing and using the released macOS app. Source builds belong in [DEVELOPMENT.md](DEVELOPMENT.md).

## Requirements

- Apple silicon Mac (arm64) running macOS 15 or later.
- Git available as `git` on `PATH` for repository operations.
- Git LFS installed separately for repositories that use it.

The built-in clone panel supports public GitHub repositories only. Existing local repositories use their configured Git remotes and authentication. See [FEATURES.md](FEATURES.md) for limitations.

## Install

1. Download the latest `Intreccio-*-macos-arm64.zip` from this repository's GitHub Releases page.
2. Verify the asset's SHA-256 digest against the digest displayed by GitHub. See [README.md](README.md) for the verification commands.
3. Extract the ZIP in Finder and move `Intreccio.app` to `/Applications`.

Releases are ad-hoc signed and not notarized. Gatekeeper may warn on first launch. After verifying the download, use Finder's Control-click > Open flow if macOS blocks the app.

If you intentionally choose to remove quarantine after verifying the download, this command targets only the named app:

```sh
xattr -dr com.apple.quarantine /Applications/Intreccio.app
```

## Configure

Add folders to watch or add repositories directly in the app. Intreccio uses the Git executable on `PATH`; configure Git's identity, remotes, and credential helpers in Git as usual. `just` is optional and only needed to run recipes from repository `justfile` files.

## Verify

```sh
open /Applications/Intreccio.app
```

The Intreccio window should open.

## Use

Choose a watched folder to discover repositories, or add a standalone repository. Select a repository to review changes, diffs, or history. See [FEATURES.md](FEATURES.md) for the complete feature list.
