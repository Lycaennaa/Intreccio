# Setup

This guide covers installing and using the released macOS app. Source builds belong in [DEVELOPMENT.md](DEVELOPMENT.md).

## Requirements

- Apple silicon Mac (arm64) running macOS 15 or later.
- Git available as `git` on `PATH` for repository operations.
- Git LFS installed separately for repositories that use it.

GitHub CLI (`gh`) is optional. To browse GitHub repositories or use the `gh` account for private clones and HTTPS Git operations, install `gh` and run `gh auth login` in Terminal. Intreccio uses that session for GitHub.com through a per-process helper, without changing global Git configuration. Existing Git credential helpers and SSH authentication continue to work. See [FEATURES.md](FEATURES.md) for limitations.

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

Add folders to watch or add repositories directly in the app. Intreccio uses the Git executable on `PATH`; configure Git's identity and remotes in Git as usual. For authenticated repository browsing, install GitHub CLI and run `gh auth login` in Terminal. Existing Git credential helpers can also authenticate clones and remote operations. `just` is optional and only needed to run recipes from repository `justfile` files.

## Verify

```sh
open /Applications/Intreccio.app
```

The Intreccio window should open.

## Use

Choose a watched folder to discover repositories, or add a standalone repository. Select a repository to review changes, diffs, or history. See [FEATURES.md](FEATURES.md) for the complete feature list.
