#!/usr/bin/env bash
set -euo pipefail

app_path="${1:-.build/derived-data/Build/Products/Release/Intreccio.app}"
output_directory="${2:-.build/release}"

if [[ ! -d "$app_path" ]]; then
    printf 'App bundle not found: %s\n' "$app_path" >&2
    exit 1
fi
if [[ ! -f LICENSE || ! -f THIRD_PARTY_NOTICES.md ]]; then
    printf 'Run this script from the repository root. LICENSE or THIRD_PARTY_NOTICES.md is missing.\n' >&2
    exit 1
fi
if [[ ! -x "$app_path/Contents/Resources/scc" ]]; then
    printf 'Bundled scc executable is missing or not executable.\n' >&2
    exit 1
fi

architectures="$(/usr/bin/lipo -archs "$app_path/Contents/MacOS/Intreccio")"
case " $architectures " in
    *" arm64 "*) ;;
    *)
        printf 'Release app must include arm64; found: %s\n' "$architectures" >&2
        exit 1
        ;;
esac

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")"
if [[ ! "$version" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
    printf 'Invalid app version: %s\n' "$version" >&2
    exit 1
fi

mkdir -p "$output_directory"
asset="$output_directory/Intreccio-$version-macos-arm64.zip"
if [[ -e "$asset" ]]; then
    printf 'Refusing to overwrite existing release asset: %s\n' "$asset" >&2
    exit 1
fi

resources="$app_path/Contents/Resources"
cp LICENSE "$resources/LICENSE.txt"
cp THIRD_PARTY_NOTICES.md "$resources/THIRD_PARTY_NOTICES.txt"
codesign --force --deep --sign - "$app_path"
codesign --verify --deep --strict "$app_path"

temporary_asset="$asset.tmp.$$"
trap 'rm -f "$temporary_asset"' EXIT
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$temporary_asset"
mv "$temporary_asset" "$asset"
trap - EXIT
printf 'Created %s\n' "$asset"
