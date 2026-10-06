Git Contract:

Exec `/usr/bin/git` direct. Never shell.
Use `git -C <repo>`; pathspecs after `--`.
Reads env: `LC_ALL=C`, `GIT_TERMINAL_PROMPT=0`, `GIT_OPTIONAL_LOCKS=0`.
Upstream fetch: configured branch remote only; credential helpers allowed, interactive prompts disabled, 30s timeout; never set `GIT_OPTIONAL_LOCKS=0`.
Mutations: no `GIT_OPTIONAL_LOCKS` override; honor user config.
Capture status/stdout/stderr. Nonzero valid only when contract says so.
Caps: 8 MiB/stream; read 30s; mutation 120s.
Show exact Git errors. Never bypass hooks/signing/identity/policy.

Project guidance:
- Build and check commands: [DEVELOPMENT.md](DEVELOPMENT.md).
- Contribution workflow and per-PR AI disclosure: [CONTRIBUTING.md](CONTRIBUTING.md).
- `project.yml` is the XcodeGen source of truth. Never hand-edit the generated `.pbxproj`.