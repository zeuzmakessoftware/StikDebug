#!/usr/bin/env python3
"""Export a verified personalized DDI from an installed Xcode into an importable folder."""

import argparse
import hashlib
import plistlib
import re
import shutil
import subprocess
import tempfile
from contextlib import contextmanager
from pathlib import Path


def export(restore: Path, output: Path, minimum_build_major: int = 27) -> str:
    manifest = plistlib.loads((restore / "BuildManifest.plist").read_bytes())
    build = manifest.get("ProductBuildVersion", "")
    match = re.match(r"^(\d+)[A-Z]", build)
    if not match or int(match[1]) < minimum_build_major:
        raise ValueError(f"DDI build {build!r} is too old; install Xcode 27 or newer.")
    if output.exists():
        raise ValueError(f"Output already exists: {output}. Choose an empty destination.")

    keys = {"PersonalizedDMG": "Image.dmg", "LoadableTrustCache": "Image.dmg.trustcache"}
    payloads = None
    for identity in manifest.get("BuildIdentities", []):
        entries = identity.get("Manifest", {})
        if not all(key in entries for key in keys):
            continue
        candidate = {}
        for key, name in keys.items():
            path = (restore / entries[key]["Info"]["Path"]).resolve()
            if not path.is_relative_to(restore.resolve()):
                raise ValueError("Manifest payload escapes the selected Restore folder.")
            if not path.is_file():
                break
            data = path.read_bytes()
            if not data or hashlib.sha384(data).digest() != entries[key].get("Digest"):
                break
            candidate[name] = data
        if len(candidate) == len(keys):
            payloads = candidate
            break
    if payloads is None:
        raise ValueError("No personalized build identity matches both the image and trust cache.")

    # Only paths change; Apple's personalization digests remain untouched.
    for identity in manifest["BuildIdentities"]:
        for key, name in keys.items():
            entry = identity.get("Manifest", {}).get(key)
            if entry is not None:
                entry["Info"]["Path"] = name
    payloads["BuildManifest.plist"] = plistlib.dumps(manifest)
    output.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix="ddi-export-", dir=output.parent))
    try:
        for name, data in payloads.items():
            (staging / name).write_bytes(data)
        staging.rename(output)
    finally:
        if staging.exists():
            shutil.rmtree(staging)
    print(f"Exported verified DDI build {build} to {output}")
    return build


@contextmanager
def attached(image: Path):
    result = subprocess.run(
        ["hdiutil", "attach", "-readonly", "-nobrowse", "-plist", str(image)],
        check=True, capture_output=True,
    )
    entities = plistlib.loads(result.stdout)["system-entities"]
    mounts = [Path(item["mount-point"]) for item in entities if "mount-point" in item]
    try:
        if not mounts:
            raise ValueError(f"No mounted filesystem in {image}")
        yield mounts[0] / "Restore"
    finally:
        for mount in mounts:
            subprocess.run(["hdiutil", "detach", str(mount)], check=True, capture_output=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, help="Xcode's expanded iOS_DDI/Restore folder")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--minimum-build-major", type=int, default=27)
    args = parser.parse_args()
    if args.source:
        export(args.source, args.output, args.minimum_build_major)
        return
    expanded = Path("/Library/Developer/DeveloperDiskImages/iOS_DDI/Restore")
    if (expanded / "BuildManifest.plist").exists():
        try:
            export(expanded, args.output, args.minimum_build_major)
            return
        except ValueError as error:
            print(f"Expanded DDI unavailable: {error}")
    candidate = Path("/Library/Developer/CoreDevice/CandidateDDIs/iOS_DDI.dmg")
    if not candidate.is_file():
        raise SystemExit("No current iOS DDI found. Install and initialize Xcode 27, or pass --source.")
    with attached(candidate) as restore:
        export(restore, args.output, args.minimum_build_major)


if __name__ == "__main__":
    main()
