# Features

This list covers features in the current app. Intreccio uses the Git installation on your Mac. Optional GitHub CLI (`gh`) support enables authenticated repository browsing, private cloning, and private remote creation; supported GitHub remotes also open in a browser.

## Repositories
- Add watched folders and discover repositories inside them.
- Add standalone repositories, create local repositories, exclude repositories from watched folders, and pin repositories.
- Clone public or private GitHub repositories, paste URLs or browse repositories available to your `gh` account. Private repository browsing requires `gh auth login`; cloning can also use an existing Git credential helper. Submodules initialize automatically and Git LFS must be installed separately.
- Create a local repository with an optional GitHub remote. Choose private (default) or public visibility and optionally add a GitHub description; creating the remote requires `gh auth login`.
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
- Filter loaded commits by subject, author, or hash; mark commits absent from the configured upstream (based on the last fetched remote state); inspect commit details and diffs.
- Stash all changes and restore the latest stash.
- Fetch configured upstreams, push the current branch to its configured upstream, and rebase on that upstream. Push is disabled for diverged branches and never force-pushes.

## Other
- Run recipes from repository `justfile` files when `just` is installed.
- Choose applications for opening folders and supported file types.
- From a repository's Open in AI Tool menu, open OMP in Apple Terminal or Tern. Tern offers a new window, a tab in its first existing window, or a right-hand split of that window's focused pane.
- Adjust diff font size, whitespace display, file-watching refresh timing, and repository sources.

## Limitations
- Authenticated repository browsing requires optional GitHub CLI (`gh`) signed in to github.com. Intreccio supports GitHub.com, not GitHub Enterprise. Private cloning and HTTPS fetch/push can use the `gh` session or other configured Git credentials; SSH remotes still require SSH credentials.
- Git LFS must be installed separately for repositories that use it.
- Direct distribution uses ad-hoc-signed, unnotarized arm64 ZIPs. macOS may warn when launching them; no App Store package is planned.
