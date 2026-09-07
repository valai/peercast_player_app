#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
checkout() {
  url=$1 revision=$2 destination="$root/native/$3"
  if [ ! -d "$destination" ]; then
    git clone --no-checkout --filter=blob:none "$url" "$destination"
    git -C "$destination" fetch --depth 1 origin "$revision"
    git -C "$destination" checkout --detach "$revision"
  fi
  test "$(git -C "$destination" rev-parse HEAD)" = "$revision" || { echo "Unexpected revision in $destination"; exit 1; }
  test -z "$(git -C "$destination" status --porcelain)" || { echo "Local changes in $destination"; exit 1; }
}
checkout https://github.com/plonk/peercast-yt b60f176317406e79a5468ba80da8be1d83bb6126 peercast-yt
checkout https://boringssl.googlesource.com/boringssl 4a92579453b35319e2707eab68a0b7d1f8d5d053 boringssl
