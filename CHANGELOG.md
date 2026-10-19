# Changelog

## Unreleased

User-visible changes for the next release will be listed here.

- Push to Origin now supports the first local commit to an empty origin and sets upstream tracking.
- Add a multi-repository Push to Origin action with per-repository selection, reusing existing status and push-access checks.

- Prevent upstream-fetch metadata events from queuing redundant repository status refreshes.

- Show active initialized submodules as nested repository rows, distinguish working-tree changes, upstream-ahead commits, and parent-pinned commit differences, and add a per-parent option to reveal clean initialized submodules. Keep pinned submodules nested once, preserve existing rows when scans are incomplete, enforce the persisted catalog limit during standalone discovery, and surface standalone scan warnings and limits.
