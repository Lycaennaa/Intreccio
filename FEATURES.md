# Features

This list covers features in the current app. Intreccio uses the Git installation on your Mac; its GitHub tools open supported remotes in a browser and clone public repositories.

## Repositories
- Add watched folders and discover repositories inside them.
- Add standalone repositories, create local repositories, exclude repositories from watched folders, and pin repositories.
- Clone public GitHub repositories, one URL per line. Submodules are initialized automatically; Git LFS must be installed separately.
- Open repositories with supported GitHub remotes in a browser.

## Changes and diffs
- Review staged, unstaged, and untracked changes.
- Stage or unstage selected files or all changes.
- Commit staged changes, amend a commit, discard changes, and add eligible unstaged files or folders to `.gitignore`.
- Inspect working-tree and commit diffs, including untracked files.
- Search diffs, move between files and hunks, show whitespace, fold context, and copy the displayed diff or raw patch.
- Open changed files or reveal them in Finder.

## History and Git workflows
- Browse Mixed, Local, Upstream, and Unmerged Upstream history.
- Filter loaded commits by subject, author, or hash; inspect commit details and diffs.
- Stash all changes and restore the latest stash.
- Rebase the current branch on its configured upstream, then continue or abort the rebase.

## Other
- Run recipes from repository `justfile` files when `just` is installed.
- Choose applications for opening folders and supported file types.
- Adjust diff font size, whitespace display, file-watching refresh timing, and repository sources.

## Limitations
- The built-in clone panel supports only public GitHub repositories. It does not support private-repository cloning or authentication. Existing local repositories use Git's configured remotes and authentication.
- Git LFS must be installed separately for repositories that use it.
- Direct distribution uses ad-hoc-signed, unnotarized arm64 ZIPs. macOS may warn when launching them; no App Store package is planned.
