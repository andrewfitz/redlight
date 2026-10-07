#!/usr/bin/env python3
"""Prepare invocation-local App Intents inputs, extract metadata, and verify bundles."""
from __future__ import annotations

import argparse
import json
import os
import pathlib
import plistlib
import re
import subprocess
import sys

APP_ACTIONS = {
    "SetRedlightIntent", "SetRedlightStateIntent", "TurnOnRedlightIntent",
    "TurnOffRedlightIntent", "SetRedlightColorIntent", "SetRedlightWhitepointIntent",
    "ResetRedlightLevelIntent", "SetRedlightPresetIntent", "SaveRedlightPresetIntent",
    "SetRedlightAdaptiveIntent", "TurnOnRedlightAdaptiveIntent", "SetRedlightLimitsIntent",
    "SetRedlightDisplayIntent", "SetRedlightInvertIntent", "SetRedlightAppearanceIntent",
    "SetRedlightLoginIntent", "UpdateRedlightIntent", "QuitRedlightIntent",
    "GetRedlightStatusIntent", "ListRedlightDisplaysIntent",
}
CONTROL_ACTIONS = {"SetRedlightIntent"}


def fail(message: str) -> None:
    raise ValueError(message)


def invocation_path(value: str, invocation: pathlib.Path) -> pathlib.Path:
    path = pathlib.Path(value).resolve()
    if not path.is_relative_to(invocation):
        fail(f"Metadata input must belong to this build invocation: {path}")
    if not path.is_file() or path.stat().st_size == 0:
        fail(f"Missing or empty metadata input from this build: {path}")
    return path


def prepare(args: argparse.Namespace) -> None:
    source = pathlib.Path(args.toolchain_dir) / "usr/share/swift/SwiftConstantValues/AppIntents.json"
    protocols = json.loads(source.read_text())
    # Xcode 27's installed object format differs from the legacy frontend array format.
    if isinstance(protocols, dict):
        protocols = protocols.get("constValueProtocols")
    if not isinstance(protocols, list) or not protocols or not all(isinstance(p, str) for p in protocols):
        fail(f"Unsupported App Intents protocol-gathering format: {source}")
    if "AppIntent" not in protocols:
        fail(f"App Intents protocol list is missing AppIntent: {source}")
    destination = pathlib.Path(args.output)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(protocols) + "\n")


def action_identifiers(metadata: pathlib.Path) -> set[str]:
    actions_file = metadata / "extract.actionsdata"
    if not actions_file.is_file():
        fail(f"Missing extracted App Intents actions: {actions_file}")
    actions = json.loads(actions_file.read_text()).get("actions")
    if not isinstance(actions, dict):
        fail(f"Invalid App Intents action dictionary: {actions_file}")
    return {action.get("identifier", key) for key, action in actions.items()}


def verify_actions(bundle: pathlib.Path, expected: set[str]) -> None:
    found = action_identifiers(bundle / "Contents/Resources/Metadata.appintents")
    missing = expected - found
    if missing:
        fail(f"App Intents metadata in {bundle.name} is missing: {', '.join(sorted(missing))}")


def verify_extension_entrypoint(executable: pathlib.Path) -> None:
    symbols = subprocess.run(["nm", "-nm", str(executable)], capture_output=True, text=True, check=True).stdout
    if not re.search(r"\(undefined\).*\b_NSExtensionMain\b", symbols):
        fail("The control extension must import Foundation's _NSExtensionMain entry point.")
    loads = subprocess.run(["otool", "-l", str(executable)], capture_output=True, text=True, check=True).stdout
    text_segment = re.search(r"segname __TEXT\s+vmaddr (0x[0-9a-fA-F]+)", loads)
    entry = re.search(r"cmd LC_MAIN\s+cmdsize \d+\s+entryoff (\d+)", loads)
    swift_main = re.search(r"^([0-9a-fA-F]+) .*\b_main$", symbols, re.MULTILINE)
    if not text_segment or not entry:
        fail("Unable to verify the control extension's Mach-O entry point.")
    entry_address = int(text_segment.group(1), 16) + int(entry.group(1))
    if swift_main and entry_address == int(swift_main.group(1), 16):
        fail("The control extension starts at Swift main instead of macOS extension bootstrap.")


def extract(args: argparse.Namespace) -> None:
    invocation = pathlib.Path(args.invocation_dir).resolve()
    constants = invocation_path(args.const_values, invocation)
    # Input provenance is path-based, not mtime-based: compilation precedes linking.
    sources = [pathlib.Path(p).resolve() for p in args.sources]
    if args.source_root:
        sources.extend(sorted(pathlib.Path(args.source_root).resolve().rglob("*.swift")))
    sources = list(dict.fromkeys(sources))
    if not sources or any(not source.is_file() for source in sources):
        fail("App Intents extraction needs existing, absolute Swift source paths.")
    source_list = invocation / f"{args.module}.sources.list"
    values_list = invocation / f"{args.module}.const-values.list"
    source_list.write_text("".join(f"{source}\n" for source in sources))
    values_list.write_text(f"{constants}\n")
    bundle = pathlib.Path(args.bundle).resolve()
    output = bundle / "Contents/Resources"
    output.mkdir(parents=True, exist_ok=True)
    subprocess.run([
        "xcrun", "appintentsmetadataprocessor",
        "--output", str(output),
        "--toolchain-dir", args.toolchain_dir,
        "--module-name", args.module,
        "--sdk-root", args.sdk_root,
        "--xcode-version", args.xcode_version,
        "--platform-family", "macOS",
        "--deployment-target", args.deployment_target,
        "--target-triple", f"arm64-apple-macosx{args.deployment_target}",
        "--source-file-list", str(source_list),
        "--swift-const-vals-list", str(values_list),
        "--deployment-aware-processing",
    ], check=True)
    verify_actions(bundle, CONTROL_ACTIONS if args.control else APP_ACTIONS)


def verify(args: argparse.Namespace) -> None:
    app = pathlib.Path(args.app).resolve()
    extension = app / "Contents/PlugIns/RedlightControl.appex"
    verify_actions(app, APP_ACTIONS)
    verify_actions(extension, CONTROL_ACTIONS)
    for bundle in (app, extension):
        subprocess.run(["plutil", "-lint", str(bundle / "Contents/Info.plist")], check=True)
    app_info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    extension_info = plistlib.loads((extension / "Contents/Info.plist").read_bytes())
    verify_extension_entrypoint(extension / "Contents/MacOS" / extension_info["CFBundleExecutable"])
    if app_info.get("CFBundleIdentifier") != "com.redlight.app" or app_info.get("LSUIElement") is not True:
        fail("App identity or menu-bar-only configuration is missing.")
    schemes = {scheme for entry in app_info.get("CFBundleURLTypes", []) for scheme in entry.get("CFBundleURLSchemes", [])}
    if "redlight" not in schemes:
        fail("The Redlight control URL scheme is missing from the app.")
    if app_info.get("LSMinimumSystemVersion") != "14.0":
        fail("The app must retain its macOS 14 minimum deployment target.")
    release_version = app_info.get("CFBundleShortVersionString")
    build_number = app_info.get("CFBundleVersion")
    if not isinstance(release_version, str) or not re.fullmatch(r"[0-9]+\.[0-9]+(?:\.[0-9]+)?", release_version):
        fail("The app release version must be numeric X.Y or X.Y.Z.")
    if not isinstance(build_number, str) or not re.fullmatch(r"[1-9][0-9]*", build_number):
        fail("The app build number must be a positive integer.")
    if (extension_info.get("CFBundleShortVersionString"), extension_info.get("CFBundleVersion")) != (release_version, build_number):
        fail("The app and Control Center extension must have the same release and build numbers.")
    if "NSExtension" in extension_info and "EXAppExtensionAttributes" in extension_info:
        fail("WidgetKit must use NSExtension registration alone; mixed ExtensionFoundation registration selects the wrong runtime.")
    if extension_info.get("LSMinimumSystemVersion") != "26.0":
        fail("The Control Center extension must require macOS 26.")
    if extension_info.get("NSExtension", {}).get("NSExtensionPointIdentifier") != "com.apple.widgetkit-extension":
        fail("The control bundle must register as a WidgetKit extension.")
    entitlements = subprocess.run(
        ["codesign", "-d", "--entitlements", ":-", str(extension)],
        capture_output=True, check=True,
    )
    extension_entitlements = plistlib.loads(entitlements.stdout)
    if extension_entitlements.get("com.apple.security.app-sandbox") is not True:
        fail("The Control Center extension is missing its app sandbox entitlement.")
    readonly_domains = extension_entitlements.get("com.apple.security.temporary-exception.shared-preference.read-only", [])
    if "com.redlight.app" not in readonly_domains:
        fail("The extension cannot read Redlight's published state/completion receipts.")
    subprocess.run(["codesign", "--verify", "--strict", "--deep", str(app)], check=True)
    print(f"Verified command metadata, bundle configuration, entitlements and signatures: {app}")


def build_info(args: argparse.Namespace) -> None:
    output = pathlib.Path(args.output_dir).resolve()
    invocation = pathlib.Path(args.invocation_dir).resolve()
    swiftpm = pathlib.Path(args.swiftpm_dir).resolve()
    if not swiftpm.is_relative_to(invocation):
        fail("SwiftPM output must belong to this build invocation.")
    info = {
        "schemaVersion": 1,
        "appVersion": args.version,
        "buildNumber": int(args.build),
        "app": str(pathlib.Path(args.app).resolve()),
        "dmg": str(pathlib.Path(args.dmg).resolve()),
        "invocationDirectory": str(invocation),
        "sparkleAppcastTool": str(swiftpm / "artifacts/sparkle/Sparkle/bin/generate_appcast"),
    }
    (output / ".redlight-build-info.json").write_text(json.dumps(info, indent=2) + "\n")


def sparkle_tool(args: argparse.Namespace) -> None:
    info_file = pathlib.Path(args.output_dir).resolve() / ".redlight-build-info.json"
    info = json.loads(info_file.read_text())
    if info.get("schemaVersion") != 1:
        fail(f"Unsupported build information: {info_file}")
    invocation = pathlib.Path(info["invocationDirectory"]).resolve()
    tool = pathlib.Path(info["sparkleAppcastTool"]).resolve()
    if not tool.is_relative_to(invocation) or not tool.is_file() or not os.access(tool, os.X_OK):
        fail(f"Missing executable Sparkle appcast tool from this build: {tool}")
    print(tool)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(required=True)
    preparation = subparsers.add_parser("prepare")
    preparation.add_argument("--toolchain-dir", required=True)
    preparation.add_argument("--output", required=True)
    preparation.set_defaults(action=prepare)
    extraction = subparsers.add_parser("extract")
    for name in ("invocation-dir", "const-values", "module", "bundle", "toolchain-dir", "sdk-root", "xcode-version", "deployment-target"):
        extraction.add_argument(f"--{name}", required=True)
    extraction.add_argument("--source-root")
    extraction.add_argument("--sources", nargs="*", default=[])
    extraction.add_argument("--control", action="store_true")
    extraction.set_defaults(action=extract)
    verification = subparsers.add_parser("verify")
    verification.add_argument("--app", required=True)
    verification.set_defaults(action=verify)
    information = subparsers.add_parser("build-info")
    for name in ("output-dir", "invocation-dir", "swiftpm-dir", "app", "dmg", "version", "build"):
        information.add_argument(f"--{name}", required=True)
    information.set_defaults(action=build_info)
    release_tool = subparsers.add_parser("sparkle-tool")
    release_tool.add_argument("--output-dir", required=True)
    release_tool.set_defaults(action=sparkle_tool)
    args = parser.parse_args()
    try:
        args.action(args)
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
