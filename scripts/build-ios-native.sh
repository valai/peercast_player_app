#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# Run prepare-native.sh once before building. Never download during Xcode signing.
command -v cmake >/dev/null || { echo 'Install CMake 3.22 or later'; exit 1; }
sdk=${PLATFORM_NAME:-iphoneos}
arch=${CURRENT_ARCH:-arm64}
if [ "$arch" = undefined_arch ]; then arch=${NATIVE_ARCH_ACTUAL:-arm64}; fi
build="$root/native/build/ios-$sdk-$arch"
cmake -S "$root/native/mobile" -B "$build" -G Xcode \
  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$sdk" \
  -DCMAKE_OSX_ARCHITECTURES="$arch" -DCMAKE_OSX_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-15.0}" \
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO
cmake --build "$build" --config Release --target peercast_mobile --parallel 4
framework=$(find "$build" -path '*/Release-*/*' -name peercast_mobile.framework -type d | head -n 1)
[ -n "$framework" ] || { echo 'Native framework missing'; exit 1; }
destination="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
mkdir -p "$destination"
ditto "$framework" "$destination/peercast_mobile.framework"
if [ "${CODE_SIGNING_ALLOWED:-NO}" = YES ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
  /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$destination/peercast_mobile.framework"
fi
