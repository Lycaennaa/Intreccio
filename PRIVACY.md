# Privacy

## Data handled

Intreccio reads the repository folders and files that you add. It processes local Git status, diffs, commit history, configured remote URLs, and repository paths. It also stores selected folders as security-scoped bookmarks so they can be reopened.

The app source contains no analytics SDK or telemetry endpoint. No account is required.

## Purpose and use

Local repository data supports discovery, status, diff, and history views. Git remote checks and public cloning use the Git executable installed on the Mac. Opening a GitHub remote launches the browser.

Refreshing an upstream can contact that repository's configured remote. Network behavior and any authentication for existing repositories follow the user's Git configuration and credential helpers. The built-in clone panel accepts public GitHub repositories only.

## Storage and retention

The app stores its repository catalog and saved UI state under `~/Library/Application Support/Intreccio/`, in `state.json` and `state.ui.json`. This includes repository sources, paths, cached repository summaries, and UI preferences. The app does not automatically expire these files. If saved data is corrupt, recovery copies named `state.corrupt-*.json` or `state.ui.corrupt-*.json` may remain in the same folder.

Remove saved sources in the app to stop tracking them. To erase all saved app state, quit Intreccio and remove the `Intreccio` folder from `~/Library/Application Support/`; this also removes saved UI preferences.

## Sharing

Intreccio does not send app state to a project-operated service. Git operations may contact configured remote hosts, and public cloning downloads repository data from GitHub. The app does not provide a push workflow.

## User choices

Choose which folders and repositories to add, and remove sources when no longer needed. Avoid adding repositories whose paths or metadata you do not want stored locally.
