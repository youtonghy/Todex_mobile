#!/bin/sh
# Usage: scripts/run_session_tests.sh
# Requires macOS 26+ and an Xcode/Swift 6.2+ toolchain selected with xcode-select.
# SwiftPM downloads the repository's dependencies into a fresh temporary build
# directory, so network access is required. Tests never start a real provider.
set -eu

if [ "$(uname -s)" != Darwin ]; then
    echo "Session tests require macOS (the app uses Security and CryptoKit)." >&2
    exit 2
fi

session_repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
session_swift=$(xcrun --find swift)
session_sdk=$(xcrun --sdk macosx --show-sdk-path)
session_work=$(mktemp -d "${TMPDIR:-/tmp}/todex-session-tests.XXXXXX")
trap 'rm -rf -- "$session_work"' 0
trap 'exit 130' INT
trap 'exit 143' TERM HUP

export TODEX_SESSION_REPO="$session_repo"
export TODEX_SESSION_TEST_DATA="$session_work/data"
mkdir -p "$session_work/Sources/SessionRaceTests" "$TODEX_SESSION_TEST_DATA"

# Copy the current application sources into a disposable executable target;
# neither the app project nor TodexCore's package manifest/build tree is edited.
cp "$session_repo/Todex/App/AppSession.swift" \
   "$session_repo/Todex/App/LocalStore.swift" \
   "$session_repo/scripts/session-tests/SessionRaceTests.swift" \
   "$session_work/Sources/SessionRaceTests/"
if [ -f "$session_repo/Packages/TodexCore/Package.resolved" ]; then
    cp "$session_repo/Packages/TodexCore/Package.resolved" "$session_work/Package.resolved"
fi
cat > "$session_work/Package.swift" <<'SWIFT'
// swift-tools-version: 6.2
import Foundation
import PackageDescription

let repository = ProcessInfo.processInfo.environment["TODEX_SESSION_REPO"]!
let package = Package(
    name: "TodexSessionRegression",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "SessionRaceTests", targets: ["SessionRaceTests"])],
    dependencies: [.package(path: repository + "/Packages/TodexCore")],
    targets: [
        .executableTarget(
            name: "SessionRaceTests",
            dependencies: [.product(name: "TodexCore", package: "todexcore")],
            swiftSettings: [
                .define("DEBUG"),
                .unsafeFlags(["-default-isolation", "MainActor"])
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
SWIFT

session_build() {
    "$session_swift" build --package-path "$session_work" \
        --scratch-path "$session_work/build" \
        --cache-path "$session_work/cache" \
        --config-path "$session_work/config" \
        --security-path "$session_work/security" \
        --manifest-cache local --sdk "$session_sdk" \
        -Xswiftc -module-cache-path -Xswiftc "$session_work/module-cache" \
        --configuration debug "$@"
}

session_build --product SessionRaceTests
session_bin=$(session_build --show-bin-path)
# A malformed URL reproduces Xcode's launch-environment normalization. The
# DEBUG fixture must prefer the port and retain the fixture-only token.
TODEX_TEST_PORT=18999 TODEX_TEST_URL=http:/normalized.invalid \
    TODEX_TEST_TOKEN=fixture-token "$session_bin/SessionRaceTests"
