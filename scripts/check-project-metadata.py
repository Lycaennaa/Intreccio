#!/usr/bin/env python3
import re
import html
import stat
import xml.etree.ElementTree as ET
import subprocess
import sys
from pathlib import Path


GIT = "/usr/bin/git"
PBX_ASSIGNMENT = re.compile(
    r'^\s*(?P<key>"?[A-Za-z_][A-Za-z0-9_]*(?:\[[^]]+\])?"?)\s*=\s*(?P<value>.*?);\s*$'
)
XCCONFIG_ASSIGNMENT = re.compile(
    r'^\s*(?P<key>"?[A-Za-z_][A-Za-z0-9_]*(?:\[[^]]+\])?"?)\s*=\s*(?P<value>.*?)\s*$'
)
YAML_ASSIGNMENT = re.compile(
    r'^\s*(?P<key>"?[A-Za-z_][A-Za-z0-9_]*(?:\[[^]]+\])?"?)\s*:\s*(?P<value>.*?)\s*$'
)
VARIABLE = re.compile(r'^"?\$\([A-Za-z_][A-Za-z0-9_]*\)"?$')
PRIVATE_PATH = re.compile(r'/(?:Users|private/var|Volumes|var/folders)/')

IDENTITY_SETTINGS = {
    "CODE_SIGN_IDENTITY",
    "DEVELOPMENT_TEAM",
    "ORGANIZATIONNAME",
    "PROVISIONING_PROFILE",
    "PROVISIONING_PROFILE_SPECIFIER",
}


def indexed_paths(root, pattern):
    result = subprocess.run(
        [GIT, "-C", str(root), "ls-files", "--stage", "-z", "--", pattern],
        check=True,
        stdout=subprocess.PIPE,
    )
    paths = []
    for record in result.stdout.decode().split("\0"):
        if not record:
            continue
        metadata, path = record.split("\t", 1)
        mode = int(metadata.split()[0], 8)
        paths.append((Path(path), mode))
    return paths


def indexed_bytes(root, path):
    result = subprocess.run(
        [GIT, "-C", str(root), "show", ":" + path.as_posix()],
        check=True,
        stdout=subprocess.PIPE,
    )
    return result.stdout


def indexed_contents(root, path):
    return indexed_bytes(root, path).decode("utf-8", errors="replace")


def parse_assignment(line, assignment):
    match = assignment.match(line)
    if not match:
        return None
    return match.group("key").strip('"'), match.group("value").strip()


def decode_xml(data):
    encodings = []
    if data.startswith((b"\xff\xfe", b"\xfe\xff")):
        encodings.append("utf-16")
    encodings.extend(("utf-8-sig", "utf-16-le", "utf-16-be"))
    for encoding in encodings:
        try:
            text = data.decode(encoding)
        except UnicodeDecodeError:
            continue
        if encoding == "utf-8-sig" and "\x00" in text:
            continue
        return text
    return data.decode("utf-8", errors="replace")


def check_xml_file(root, path):
    data = indexed_bytes(root, path)
    decoded = html.unescape(decode_xml(data))
    failures = []
    if PRIVATE_PATH.search(decoded):
        failures.append((1, "contains a machine-specific absolute path"))
    try:
        root_element = ET.fromstring(data)
    except (ET.ParseError, UnicodeError):
        failures.append((1, "invalid Xcode XML metadata"))
        return failures

    values = []
    for element in root_element.iter():
        values.extend((element.tag, element.text, element.tail))
        values.extend(element.attrib.keys())
        values.extend(element.attrib.values())
    for value in values:
        if value is None:
            continue
        if PRIVATE_PATH.search(value):
            failures.append((1, "contains a machine-specific absolute path"))
    return failures


def check_file(root, path, mode):
    if not stat.S_ISREG(mode):
        return [(1, "must be a regular file in the Git index")]
    if path.suffix in {".xcworkspacedata", ".xcscheme"}:
        return check_xml_file(root, path)

    failures = []
    assignment = (
        YAML_ASSIGNMENT if path.suffix in {".yml", ".yaml"} else
        XCCONFIG_ASSIGNMENT if path.suffix == ".xcconfig" else PBX_ASSIGNMENT
    )
    for line_number, line in enumerate(indexed_contents(root, path).splitlines(), 1):
        decoded_line = html.unescape(line)
        if PRIVATE_PATH.search(line) or PRIVATE_PATH.search(decoded_line):
            failures.append((line_number, "contains a machine-specific absolute path"))

        parsed = parse_assignment(line, assignment) if assignment else None
        if not parsed:
            continue
        key, value = parsed
        base_key = key.split("[", 1)[0]

        if base_key in {"PRODUCT_NAME", "PRODUCT_BUNDLE_IDENTIFIER"}:
            if not VARIABLE.fullmatch(value):
                failures.append(
                    (line_number, f"{base_key} must reference a build setting variable")
                )
        elif base_key in IDENTITY_SETTINGS:
            if value not in {"\"\"", "-"} and not VARIABLE.fullmatch(value):
                failures.append((line_number, f"{base_key} contains a local identity"))

    return failures


def main():
    root = Path(__file__).resolve().parents[1]
    indexed = []
    for pattern in (
        "*.pbxproj",
        "*.xcconfig",
        "*.xcworkspacedata",
        "*.xcscheme",
        "project.yml",
    ):
        indexed.extend(indexed_paths(root, pattern))

    failures = []
    for path, mode in indexed:
        failures.extend(
            (path, line_number, reason)
            for line_number, reason in check_file(root, path, mode)
        )

    if not failures:
        return 0

    print("project metadata check failed:", file=sys.stderr)
    for path, line_number, reason in failures:
        print(f"  {path}:{line_number}: {reason}", file=sys.stderr)
    print(
        "Move product/signing values to an xcconfig or xcodebuild command-line override.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
