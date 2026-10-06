# Architecture

## Overview

Intreccio is a native macOS Git client. The app coordinates watched-folder discovery, local repository operations, persisted state, and the UI.

## Components

- `Intreccio/App` starts the app and coordinates app lifecycle and snapshots.
- `Intreccio/UI` presents repository sources, changes, diffs, history, and settings.
- `RepositoryCatalog` and `RepoScanner` manage sources and bounded repository discovery.
- `GitService` delegates Git operations to a process runner and parses their results. The bundled `scc` executable supplies source-line statistics.
- `StateStore` persists the repository catalog and UI state as JSON under Application Support.
- `IntreccioTests` and `IntreccioIntegrationTests` cover unit and app integration behavior.

## Key flows

1. The user adds a watched folder or standalone repository.
2. The catalog scans watched folders, records discovered repositories, and publishes an app snapshot.
3. The runtime refreshes Git status and requested history or diff data through `GitService`.
4. The app persists source and UI state locally and the UI renders the resulting snapshot.

## Constraints and decisions

- The app targets macOS 15 or later and uses Swift 6 concurrency checking.
- The App Sandbox is disabled so the app can access selected repositories and launch Git. macOS user permissions still apply.
- `project.yml` is the XcodeGen source of truth; `Intreccio.xcodeproj` is generated.
