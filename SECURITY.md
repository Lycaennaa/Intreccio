# Security

## Security-sensitive behavior

Intreccio is not App Sandbox-enabled. It reads and modifies repositories using the current user's macOS permissions, launches the system Git executable, and can run recipes from repository `justfile` files.

## Safe use

- Add only folders and repositories you trust.
- Review a repository's `justfile` before running its recipes; recipes can execute arbitrary commands as your user.
- Review the target and working tree before discarding changes, amending commits, rebasing, or pushing.
- Existing repository network operations use configured remotes and Git credential helpers. Optional GitHub CLI authentication supports private cloning and repository browsing. Push only targets the current branch's configured upstream and never force-pushes.

## Limitations

The disabled App Sandbox means macOS permissions and user judgment are the primary boundaries for filesystem access and subprocess execution.
