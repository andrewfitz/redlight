#!/usr/bin/env python3
"""Choose a release version, reserve a build number, and publish build artifacts."""
from __future__ import annotations

import argparse
import fcntl
import json
import os
import pathlib
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from xml.parsers.expat import ExpatError

RELEASE_PATTERN = re.compile(r"[0-9]+\.[0-9]+(?:\.[0-9]+)?\Z")
NUMERIC_BUILD_PATTERN = re.compile(r"[0-9]+(?:\.[0-9]+){0,2}\Z")


def git_output(root: pathlib.Path, *arguments: str) -> str:
    try:
        result = subprocess.run(["git", "-C", str(root), *arguments],
                                capture_output=True, text=True, check=False)
    except OSError:
        return ""
    return result.stdout.strip() if result.returncode == 0 else ""


def release_version(root: pathlib.Path, override: str | None = None) -> str:
    if override is not None:
        if not RELEASE_PATTERN.fullmatch(override):
            raise ValueError("VERSION must be numeric X.Y or X.Y.Z, for example 1.3.")
        return override
    version_file = root / "VERSION"
    if version_file.exists():
        current = version_file.read_text().strip()
        if not RELEASE_PATTERN.fullmatch(current):
            raise ValueError(f"{version_file} must contain a numeric release version X.Y or X.Y.Z.")
        return current
    tags = [tag[1:] for tag in git_output(root, "tag", "--list").splitlines()
            if tag.startswith("v") and RELEASE_PATTERN.fullmatch(tag[1:])]
    if not tags:
        return "1.0"

    def version_key(tag: str) -> tuple[int, ...]:
        parts = tuple(map(int, tag.split(".")))
        return parts + (0,) * (3 - len(parts))

    return max(tags, key=version_key)


def tracked_commit_count(root: pathlib.Path) -> int:
    count = git_output(root, "rev-list", "--count", "HEAD")
    return int(count) if count.isdecimal() else 0


def app_build_seed(app: pathlib.Path) -> int:
    try:
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    except (OSError, ValueError, ExpatError):
        return 0
    value = info.get("CFBundleVersion") if isinstance(info, dict) else None
    if not isinstance(value, str) or not NUMERIC_BUILD_PATTERN.fullmatch(value):
        return 0
    # A new integer greater than the old major is also greater than a dotted old build.
    return int(value.split(".")[0])


def read_counter(state: pathlib.Path) -> int:
    if not state.exists():
        return 0
    try:
        data = json.loads(state.read_text())
        number = data["lastBuildNumber"]
        schema = data.get("schemaVersion")
        if type(schema) is not int or schema != 1 or type(number) is not int or number < 1:
            raise ValueError("invalid counter")
        return number
    except (OSError, ValueError, TypeError, KeyError) as error:
        raise ValueError(f"Cannot read build counter {state}; refusing to reset it.") from error


def write_counter(state: pathlib.Path, number: int) -> None:
    descriptor, temporary = tempfile.mkstemp(prefix=f".{state.name}.", dir=state.parent)
    try:
        with os.fdopen(descriptor, "w") as stream:
            json.dump({"schemaVersion": 1, "lastBuildNumber": number}, stream)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, state)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def next_build_number(state: pathlib.Path, seed: int = 0, override: str | None = None) -> int:
    state = state.resolve()
    state.parent.mkdir(parents=True, exist_ok=True)
    # A separate lock inode stays stable while the counter file is replaced atomically.
    with state.with_name(state.name + ".lock").open("a+b") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        previous = max(read_counter(state), seed)
        if override is None:
            number = previous + 1
        else:
            number = int(override) if re.fullmatch(r"[0-9]+", override) else 0
            if number < 1:
                raise ValueError("BUILD_NUMBER must be a positive integer.")
            if number <= previous:
                raise ValueError(f"BUILD_NUMBER must exceed previous build {previous}; received {number}.")
        write_counter(state, number)
        return number


def publish_build(stage: pathlib.Path, output: pathlib.Path, release: str, number: int,
                  snapshot: pathlib.Path | None = None) -> None:
    if not RELEASE_PATTERN.fullmatch(release) or number < 1:
        raise ValueError("Cannot publish invalid release or build numbers.")
    app = output / "Redlight.app"
    dmg = output / f"Redlight-{release}.dmg"
    receipt = output / ".redlight-build-info.json"
    artifacts = ((stage / "volume/Redlight.app", app),
                 (stage / "Redlight.dmg", dmg),
                 (stage / receipt.name, receipt))

    directory = os.open(output, os.O_RDONLY)
    try:
        fcntl.flock(directory, fcntl.LOCK_EX)
        previous = app_build_seed(app)
        if previous >= number:
            raise ValueError(f"Build {number} cannot replace build {previous} in {output}.")
        backups = []
        installed = []
        snapshot_created = False
        try:
            if snapshot is not None:
                # Release tooling uses the exact archive and receipt produced together here.
                snapshot.mkdir()
                snapshot_created = True
                shutil.copyfile(stage / "Redlight.dmg", snapshot / dmg.name)
                shutil.copyfile(stage / receipt.name, snapshot / receipt.name)
            for source, target in artifacts:
                if target.exists() or target.is_symlink():
                    if target.is_dir() and (target != app or target.is_symlink()):
                        raise IsADirectoryError(target)
                    backup = stage / ("previous-" + target.name)
                    target.rename(backup)
                    backups.append((backup, target))
                source.rename(target)
                installed.append((target, source))
        except BaseException:
            for source, target in reversed(backups + installed):
                try:
                    source.rename(target)
                except OSError as error:
                    print(f"error: could not restore {target} from {source}: {error}", file=sys.stderr)
            if snapshot_created:
                shutil.rmtree(snapshot)
            raise
    finally:
        os.close(directory)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(required=True, dest="command")
    release = subparsers.add_parser("release")
    release.add_argument("--root", required=True, type=pathlib.Path)
    release.add_argument("--override")
    build = subparsers.add_parser("next")
    build.add_argument("--root", required=True, type=pathlib.Path)
    build.add_argument("--state", required=True, type=pathlib.Path)
    build.add_argument("--seed-app", action="append", default=[], type=pathlib.Path)
    build.add_argument("--override")
    publication = subparsers.add_parser("publish")
    publication.add_argument("--stage", required=True, type=pathlib.Path)
    publication.add_argument("--output-dir", required=True, type=pathlib.Path)
    publication.add_argument("--version", required=True)
    publication.add_argument("--build", required=True, type=int)
    publication.add_argument("--snapshot-dir", type=pathlib.Path)
    args = parser.parse_args()
    try:
        if args.command == "release":
            print(release_version(args.root, args.override))
        elif args.command == "next":
            seed = max([tracked_commit_count(args.root)] + [app_build_seed(app) for app in args.seed_app])
            print(next_build_number(args.state, seed, args.override))
        else:
            publish_build(args.stage, args.output_dir, args.version, args.build, args.snapshot_dir)
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
