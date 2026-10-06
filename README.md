# Intreccio

Intreccio is a native macOS Git client that discovers repositories in folders you choose and helps you work with local changes, diffs, and history.

## Quick start

Download the latest macOS release ZIP from this repository's GitHub Releases page and follow [SETUP.md](SETUP.md). After installation:

```sh
open /Applications/Intreccio.app
```

## Verify downloads

Compare the SHA-256 digest of the downloaded asset with the digest shown on its GitHub release page. GitHub provides the asset digest; this project does not generate a separate checksum file.

```sh
shasum -a 256 "$HOME/Downloads/Intreccio-0.1.0-macos-arm64.zip"
```

Release ZIPs also carry GitHub build provenance. Run this from a clone of the repository with GitHub CLI installed:

```sh
gh attestation verify "$HOME/Downloads/Intreccio-0.1.0-macos-arm64.zip" \
  --repo "$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
```

The command should report a verified attestation for the repository.

## First launch on macOS

Release ZIPs are ad-hoc signed and not notarized, so Gatekeeper may warn on first launch. After verifying the download, use Finder's Control-click > Open flow if macOS blocks the app. If you intentionally choose to remove quarantine after verification, this command targets only the app bundle:

```sh
xattr -dr com.apple.quarantine /Applications/Intreccio.app
```

## Docs

- [Features](FEATURES.md)
- [Privacy](PRIVACY.md)
- [Setup](SETUP.md)
- [Development](DEVELOPMENT.md)
- [Support](SUPPORT.md)
- [Full documentation index](DOCUMENTATION.md)
- [License](LICENSE) 
- [Third-party notices](THIRD_PARTY_NOTICES.md)
