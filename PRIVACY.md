# Privacy

## Data handled

Intreccio reads the repository folders and files that you add. It processes local Git status, diffs, commit history, configured remote URLs, and repository paths. It also stores selected folders as security-scoped bookmarks so they can be reopened.

The app source contains no analytics SDK or telemetry endpoint. No account is required. Optional GitHub features use the account configured in GitHub CLI (`gh`); Intreccio does not store or display the account token.

## Purpose and use

Local repository data supports discovery, status, diff, and history views. Git remote checks and cloning use the Git executable installed on the Mac. Opening a GitHub remote launches the browser. When requested, `gh` lists repositories available to the authenticated account or creates a GitHub repository with the selected visibility.

Creating a GitHub remote sends the repository name and optional description to GitHub, then configures it as `origin`. Public visibility makes the repository and its metadata visible to everyone. The command does not push local files. HTTPS GitHub Git operations can use `gh auth git-credential` through a per-process Git configuration; Intreccio does not modify global Git configuration. SSH remotes continue to use the user's configured SSH authentication. Repository browsing and remote creation require `gh auth login`; cloning can also use existing Git credentials.

## Storage and retention

The app stores its repository catalog and saved UI state under `~/Library/Application Support/Intreccio/`, in `state.json` and `state.ui.json`. This includes repository sources, paths, cached repository summaries, and UI preferences. The app does not automatically expire these files. If saved data is corrupt, recovery copies named `state.corrupt-*.json` or `state.ui.corrupt-*.json` may remain in the same folder.

Remove saved sources in the app to stop tracking them. To erase all saved app state, quit Intreccio and remove the `Intreccio` folder from `~/Library/Application Support/`; this also removes saved UI preferences.

## Sharing

Intreccio does not send app state to a project-operated service. Git operations may contact configured remote hosts; repository browsing calls GitHub through `gh`, and cloning downloads repository data from GitHub. The app can push the current branch to its configured upstream without force-pushing.

## User choices

Choose which folders and repositories to add, and remove sources when no longer needed. Avoid adding repositories whose paths or metadata you do not want stored locally.
