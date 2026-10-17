# Distill wraps Xcode, Swift and SwiftLint commands and has native fallbacks.
# https://github.com/lycaennaa/distill

@default:
    just --list

@setup:
    xcodegen generate --spec project.yml

@generate-project:
    xcodegen generate --spec project.yml

@build: generate-project
    if command -v distill >/dev/null 2>&1; then distill xcode build -- -project Intreccio.xcodeproj -scheme Intreccio -configuration Debug -derivedDataPath .build/derived-data CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO SDKROOT=auto; else xcodebuild -project Intreccio.xcodeproj -scheme Intreccio -configuration Debug -derivedDataPath .build/derived-data CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO SDKROOT=auto build; fi

@build-release: generate-project
    if command -v distill >/dev/null 2>&1; then distill xcode build -- -project Intreccio.xcodeproj -scheme Intreccio -configuration Release -derivedDataPath .build/derived-data ARCHS=arm64 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO SDKROOT=auto; else xcodebuild -project Intreccio.xcodeproj -scheme Intreccio -configuration Release -derivedDataPath .build/derived-data ARCHS=arm64 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO SDKROOT=auto build; fi

@build-release-omv: generate-project
    if command -v distill >/dev/null 2>&1; then distill xcode build --omv -- -project Intreccio.xcodeproj -scheme Intreccio -configuration Release -derivedDataPath .build/derived-data ARCHS=arm64 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO SDKROOT=auto; else xcodebuild -project Intreccio.xcodeproj -scheme Intreccio -configuration Release -derivedDataPath .build/derived-data ARCHS=arm64 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO SDKROOT=auto build; fi

@test: generate-project
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p .build
    result_bundle=".build/test-results.$$.xcresult"
    printf 'XCTest result bundle retained on failure: %s\n' "$result_bundle"
    status=0
    if command -v distill >/dev/null 2>&1; then
        distill xcode test -- -project Intreccio.xcodeproj -scheme Intreccio -configuration Debug -derivedDataPath .build/derived-data -resultBundlePath "$result_bundle" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO SDKROOT=auto || status=$?
    else
        xcodebuild -project Intreccio.xcodeproj -scheme Intreccio -configuration Debug -derivedDataPath .build/derived-data -resultBundlePath "$result_bundle" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO SDKROOT=auto test || status=$?
    fi
    if [[ "$status" -eq 0 ]]; then rm -rf "$result_bundle"; fi
    exit "$status"

@lint:
    if command -v distill >/dev/null 2>&1; then distill swift lint -- --config .swiftlint.yml --baseline .swiftlint-baseline.yml --strict; else swiftlint lint --config .swiftlint.yml --baseline .swiftlint-baseline.yml --strict; fi

@lint-fix:
    if command -v distill >/dev/null 2>&1; then distill swift lint -- --config .swiftlint.yml --fix --lenient; else swiftlint lint --config .swiftlint.yml --fix --lenient; fi
    just lint

@check: check-project check-tooling check-project-metadata lint test

@ci: check-ci-toolchain check-project check-tooling check-project-metadata lint test build-release

@run: build
    open .build/derived-data/Build/Products/Debug/Intreccio.app

@clean:
    rm -rf .build/derived-data .build/test-results.*.xcresult

@package: build-release
    bash scripts/package-app.sh

@check-ci-toolchain:
    #!/usr/bin/env bash
    set -euo pipefail
    test "$(uname -s)" = Darwin
    if [ -n "${XCODE_DEVELOPER_DIR:-}" ]; then export DEVELOPER_DIR="$XCODE_DEVELOPER_DIR"; fi
    xcode-select --print-path
    xcode_output="$(xcodebuild -version)"
    printf '%s\n' "$xcode_output"
    xcode_version="$(printf '%s\n' "$xcode_output" | awk 'NR == 1 { print $2 }')"
    XCODE_VERSION="$xcode_version" python3 - <<'PY'
    import os
    import re
    version = tuple(int(part) for part in re.findall(r"\d+", os.environ["XCODE_VERSION"])[:2])
    if version < (26, 6):
        raise SystemExit(f"Xcode 26.6 or later required; found {os.environ['XCODE_VERSION']}")
    PY
    swift --version
    python3 --version

@check-project: generate-project
    test -f "Intreccio.xcodeproj/project.pbxproj"

@check-tooling:
    python3 -B scripts/check-package-locks.py

@check-project-metadata:
    python3 -B scripts/check-project-metadata.py

