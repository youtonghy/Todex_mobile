#!/usr/bin/env python3
"""Build and run UIKit UI tests against an explicitly owned local Rust fixture."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
from urllib.parse import urlparse

from backend_fixture import read_fixture


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", required=True)
    parser.add_argument("--device", required=True, help="Simulator UDID from xcrun simctl list devices")
    parser.add_argument("--derived-data", default="/tmp/todex-mobile-derived")
    parser.add_argument("--xcode", default="/Applications/Xcode-beta.app")
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--only-testing", help="Optional XCTest identifier, e.g. TodexUITests/TodexUITests/testDarkAppearanceAndLargeText")
    args = parser.parse_args()
    root, fixture = read_fixture(args.fixture)
    parsed = urlparse(fixture["url"])
    if parsed.scheme != "http" or parsed.hostname != "127.0.0.1" or parsed.port != fixture["port"]:
        raise ValueError("UI tests require the owned local fixture, not a real backend")
    token = (root / "token.txt").read_text().strip()
    derived = Path(args.derived_data).resolve()
    repository = Path(__file__).resolve().parents[1]
    env = dict(os.environ)
    env["DEVELOPER_DIR"] = str(Path(args.xcode) / "Contents/Developer")
    destination = "platform=iOS Simulator,id=" + args.device
    if not args.skip_build:
        subprocess.run(["xcodebuild", "-project", str(repository / "Todex.xcodeproj"), "-scheme", "Todex",
                        "-configuration", "Debug", "-destination", destination,
                        "-derivedDataPath", str(derived), "-skipPackagePluginValidation",
                        "CODE_SIGNING_ALLOWED=NO", "build-for-testing"], cwd=repository, env=env, check=True)
    runs = sorted((derived / "Build/Products").glob("*.xctestrun"), key=lambda path: path.stat().st_mtime)
    if not runs:
        raise FileNotFoundError("Build for testing first; no .xctestrun file exists")
    run = plistlib.loads(runs[-1].read_bytes())
    configured = 0

    def visit(value):
        nonlocal configured
        if isinstance(value, dict):
            if value.get("IsUITestBundle") is True:
                # TestingEnvironmentVariables is reserved for test-loader paths;
                # Xcode path-normalizes values there (http:// becomes http:/).
                value.setdefault("EnvironmentVariables", {}).update(TODEX_TEST_PORT=str(fixture["port"]), TODEX_TEST_TOKEN=token)
                configured += 1
            for child in value.values():
                visit(child)
        elif isinstance(value, list):
            for child in value:
                visit(child)

    visit(run)
    if not configured:
        raise ValueError("Xcode run file has no UI test target")
    # __TESTROOT__ in Xcode's run file is relative to that file, so keep it beside the original.
    descriptor, name = tempfile.mkstemp(prefix="Todex-Fixture-", suffix=".xctestrun", dir=runs[-1].parent)
    with os.fdopen(descriptor, "wb") as handle:
        plistlib.dump(run, handle)
    result = root / ("ui-" + args.device + "-" + str(int(__import__("time").time())) + ".xcresult")
    try:
        command = ["xcodebuild", "test-without-building", "-xctestrun", name,
                        "-destination", destination, "-parallel-testing-enabled", "NO",
                        "-collect-test-diagnostics", "never",
                        "-resultBundlePath", str(result)]
        if args.only_testing:
            command.append("-only-testing:" + args.only_testing)
        subprocess.run(command, cwd=repository, env=env, check=True)
    finally:
        Path(name).unlink(missing_ok=True)
    print("UI result:", result)


if __name__ == "__main__":
    main()
