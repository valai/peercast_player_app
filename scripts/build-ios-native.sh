#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

# Required tools
command -v cmake >/dev/null || {
  echo 'Install CMake 3.22 or later'
  exit 1
}

command -v xcrun >/dev/null || {
  echo 'xcrun was not found. Install/configure Xcode Command Line Tools.'
  exit 1
}

sdk=${PLATFORM_NAME:-iphoneos}
arch=${CURRENT_ARCH:-}

# Xcode 26 may provide CURRENT_ARCH=undefined_arch
# and NATIVE_ARCH_ACTUAL=arm64e.
# Normalize them to a valid target architecture.
if [ -z "$arch" ] || [ "$arch" = "undefined_arch" ] || [ "$arch" = "arm64e" ]; then
  if [ "$sdk" = "iphonesimulator" ]; then
    host_arch=$(uname -m)

    case "$host_arch" in
      arm64|arm64e)
        arch=arm64
        ;;
      x86_64)
        arch=x86_64
        ;;
      *)
        arch=arm64
        ;;
    esac
  else
    arch=arm64
  fi
fi

cc=$(xcrun --sdk "$sdk" --find clang)
cxx=$(xcrun --sdk "$sdk" --find clang++)
sysroot=$(xcrun --sdk "$sdk" --show-sdk-path)

echo "PeerCast Native build:"
echo "  SDK:     $sdk"
echo "  ARCH:    $arch"
echo "  CC:      $cc"
echo "  CXX:     $cxx"
echo "  SYSROOT: $sysroot"

build="$root/native/build/ios-$sdk-$arch"

# Do not let the outer Xcode build's architecture/compiler settings
# leak into CMake's independent native build.
unset ARCHS
unset ARCHS_STANDARD
unset ARCHS_STANDARD_32_64_BIT
unset ARCHS_STANDARD_64_BIT
unset ARCHS_STANDARD_INCLUDING_64_BIT
unset ARCHS_UNIVERSAL_IPHONE_OS

unset CURRENT_ARCH
unset NATIVE_ARCH
unset NATIVE_ARCH_32_BIT
unset NATIVE_ARCH_64_BIT
unset NATIVE_ARCH_ACTUAL
unset PLATFORM_PREFERRED_ARCH
unset ONLY_ACTIVE_ARCH

unset CC
unset CXX

# Use a command-line CMake generator instead of the Xcode generator.
# This avoids Xcode 26's __preview.dylib CompilerId issue.
cmake \
  -S "$root/native/mobile" \
  -B "$build" \
  -G "Unix Makefiles" \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT="$sysroot" \
  -DCMAKE_OSX_ARCHITECTURES="$arch" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-15.0}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="$cc" \
  -DCMAKE_CXX_COMPILER="$cxx" \
  -DCMAKE_MACOSX_BUNDLE=OFF \
  -DCMAKE_SKIP_INSTALL_RULES=ON \
  -DBUILD_TESTING=OFF

cmake \
  --build "$build" \
  --target peercast_mobile \
  --parallel 4

framework=$(find "$build" \
  -name peercast_mobile.framework \
  -type d \
  | head -n 1)

[ -n "$framework" ] || {
  echo 'Native framework missing'
  exit 1
}

echo "PeerCast Native framework:"
echo "  $framework"

destination="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"

mkdir -p "$destination"
ditto "$framework" "$destination/peercast_mobile.framework"

if [ "${CODE_SIGNING_ALLOWED:-NO}" = YES ] &&
   [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
  /usr/bin/codesign \
    --force \
    --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
    "$destination/peercast_mobile.framework"
fi