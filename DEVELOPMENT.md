# Development

This guide covers source changes, builds, and checks. For end-user installation and use, see [SETUP.md](SETUP.md).

## Requirements

- macOS 15 or later.
- Xcode 26.6 or later.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen).
- [SwiftLint](https://github.com/realm/SwiftLint).
- [Just](https://github.com/casey/just#installation).
- Git available as `git` on `PATH`.
- Distill is optional; local recipes use it when installed and otherwise use native tools.

## Get the source

Clone the GitHub repository and run commands from its root:

```sh
just setup
```

`just setup` generates the Xcode project from `project.yml`. Install XcodeGen before running it.

## Xcode project

`project.yml` is the XcodeGen source of truth. XcodeGen creates `Intreccio.xcodeproj`; never hand-edit generated project files. Build and test recipes generate the project automatically.

There are no checked-in SwiftPM `Package.resolved` files. `scripts/check-package-locks.py` keeps the empty lockfile list explicit; update it if Swift packages are added.

To generate the project directly:

```sh
just generate-project
```

## Build and test

```sh
just build
just build-release
just test
```

`just build-release` builds the arm64 release app without signing. `just package` additionally creates an ad-hoc-signed, unnotarized ZIP in `.build/release`.

## Checks

```sh
just check
just ci
just lint-fix
```

`just check` generates the project from `project.yml`, validates Xcode metadata and Swift package lock configuration, runs SwiftLint against the checked-in baseline, and runs both XCTest targets. New lint findings fail the strict check. `just ci` also verifies the local Xcode version and builds the Release configuration. GitHub Actions uses native commands in `.github/workflows/ci.yml` rather than Just or Distill.

`just lint-fix` applies SwiftLint autocorrections, then reruns the strict baseline check. Review source changes before keeping them.

See [CONTRIBUTING.md](CONTRIBUTING.md) for pull-request expectations.

For maintainer release procedures, see [RELEASE.md](RELEASE.md).
