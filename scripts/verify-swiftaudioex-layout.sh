#!/bin/bash
# Owner decision, 2026-11-17: the iOS standard load's byte progress reads SwiftAudioEx 1.1.0's
# private layout by reflection (standardPlayerItem in ios/RNTrackPlayer/PlaybackBackend.swift:
# AudioPlayer.wrapper -> AVPlayerWrapper.avPlayer), with the podspec pinned to exactly 1.1.0.
# This guard compiles the real SwiftAudioEx 1.1.0 sources with PlaybackBackend.swift (as is) and
# scripts/swiftaudioex-layout-guard/main.swift for Mac Catalyst, so it runs natively on this Mac
# (no simulator), and fails when standardPlayerItem does not read a real QueuedAudioPlayer's
# AVPlayer item. The XCTest target cannot build SwiftAudioEx (it compiles PlaybackBackend.swift
# alone; its fake-layout test, testStandardPlayerItemIsReadThroughSwiftAudioExsPrivateWrapper,
# runs in CI), so this runs where the 1.1.0 sources are: $SWIFTAUDIOEX_SOURCES, the CocoaPods
# cache, or an installed example/ios/Pods. Without them it prints SKIPPED and exits 0 (nothing is
# downloaded). Usage: scripts/verify-swiftaudioex-layout.sh
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)

pin=$(grep -E '^\s*s\.dependency "SwiftAudioEx"' "$root/react-native-track-player.podspec" || true)
if [[ "$pin" != *'s.dependency "SwiftAudioEx", "1.1.0"' ]]; then
  echo "FAIL: the podspec must pin SwiftAudioEx to exactly 1.1.0 (found: ${pin:-none})"
  exit 1
fi

sources=${SWIFTAUDIOEX_SOURCES:-}
if [[ -z "$sources" ]]; then
  for candidate in "$HOME"/Library/Caches/CocoaPods/Pods/Release/SwiftAudioEx/1.1.0-*/Sources/SwiftAudioEx \
    "$root/example/ios/Pods/SwiftAudioEx/Sources/SwiftAudioEx"; do
    if [[ -d "$candidate" ]]; then
      # The example's Pods must be 1.1.0 (its Podfile.lock says which).
      if [[ "$candidate" == "$root/example/ios/Pods/"* ]] && ! grep -q "SwiftAudioEx (1.1.0)" "$root/example/ios/Podfile.lock" 2>/dev/null; then
        continue
      fi
      sources=$candidate
      break
    fi
  done
fi
if [[ -z "$sources" || ! -d "$sources" ]]; then
  echo "SKIPPED: no SwiftAudioEx 1.1.0 sources (set SWIFTAUDIOEX_SOURCES, or run pod install for the example)"
  exit 0
fi
if [[ "$(uname)" != "Darwin" ]]; then
  echo "SKIPPED: needs macOS (Mac Catalyst)"
  exit 0
fi

build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT
sdk=$(xcrun --show-sdk-path --sdk macosx)
catalyst=(-sdk "$sdk" -target arm64-apple-ios15.0-macabi
  -Fsystem "$sdk/System/iOSSupport/System/Library/Frameworks"
  -I "$sdk/System/iOSSupport/usr/lib/swift" -L "$sdk/System/iOSSupport/usr/lib/swift")
if [[ "$(uname -m)" != "arm64" ]]; then
  catalyst=("${catalyst[@]/arm64-apple-ios15.0-macabi/x86_64-apple-ios15.0-macabi}")
fi
(cd "$build" && xcrun swiftc "${catalyst[@]}" -suppress-warnings -parse-as-library -emit-library -static -emit-module \
  -module-name SwiftAudioEx -o "$build/libSwiftAudioEx.a" -emit-module-path "$build/SwiftAudioEx.swiftmodule" \
  $(find "$sources" -name '*.swift'))
xcrun swiftc "${catalyst[@]}" -suppress-warnings -I "$build" -L "$build" -lSwiftAudioEx -module-name SwiftAudioExLayoutGuard \
  -o "$build/guard" "$root/ios/RNTrackPlayer/PlaybackBackend.swift" "$root/scripts/swiftaudioex-layout-guard/main.swift"
echo "SwiftAudioEx sources: $sources"
"$build/guard"
