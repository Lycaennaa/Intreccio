#!/usr/bin/env python3
import json
import sys
from pathlib import Path


LOCKFILES: tuple[Path, ...] = ()


def normalized_pins(path):
    try:
        document = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot read {path}: {error}") from error

    pins = []
    for pin in document.get("pins", []):
        state = pin.get("state", {})
        pins.append(
            (
                pin.get("identity"),
                pin.get("location"),
                state.get("revision"),
                state.get("version"),
            )
        )
    return tuple(sorted(pins))


def main():
    if not LOCKFILES:
        print("No SwiftPM Package.resolved files configured; lock comparison is not applicable.")
        return 0
    missing = [str(path) for path in LOCKFILES if not path.is_file()]
    if missing:
        print("missing Swift package lockfile(s):", ", ".join(missing), file=sys.stderr)
        return 1

    expected = normalized_pins(LOCKFILES[0])
    failures = []
    for path in LOCKFILES[1:]:
        actual = normalized_pins(path)
        if actual != expected:
            failures.append((path, actual))

    if failures:
        print("Swift package lockfiles disagree:", file=sys.stderr)
        print(f"  {LOCKFILES[0]}: {expected}", file=sys.stderr)
        for path, actual in failures:
            print(f"  {path}: {actual}", file=sys.stderr)
        return 1

    if len(LOCKFILES) == 1:
        print(
            f"Swift package lockfile is valid ({len(expected)} pin(s)); only one configured"
        )
    else:
        print(f"Swift package lockfiles agree on {len(expected)} pin(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
