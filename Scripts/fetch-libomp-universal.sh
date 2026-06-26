#!/usr/bin/env bash
#
# Build a universal (arm64 + x86_64) libomp.dylib into vendor/.
# The arm64 slice comes from the local Homebrew libomp; the x86_64 slice is pulled from
# Homebrew's ghcr bottle for the SAME version (Microsoft/Homebrew don't ship an x86_64
# libomp we can `brew install` on Apple Silicon, so we fetch the bottle blob directly).
# Gitignored output, fetched on demand. Used by notarize_app.sh for the universal/Intel builds.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/vendor"
OUT="$VENDOR/libomp-universal.dylib"
ARM_OMP="/opt/homebrew/opt/libomp/lib/libomp.dylib"
TOKEN="QQ=="   # Homebrew's anonymous ghcr bearer token

mkdir -p "$VENDOR"
[ -f "$ARM_OMP" ] || { echo "arm64 libomp missing — run: brew install libomp"; exit 1; }
VER="$(brew list --versions libomp | awk '{print $NF}')"

echo "Building universal libomp ${VER}..."
api() { curl -fsSL -H "Authorization: Bearer $TOKEN" "$@"; }

# 1. manifest index → pick an x86_64 macOS bottle tag (no arm64_ / linux), prefer sonoma (macOS 14)
INDEX="$(api -H 'Accept: application/vnd.oci.image.index.v1+json' \
  "https://ghcr.io/v2/homebrew/core/libomp/manifests/$VER")"
PLATFORM_DIGEST="$(echo "$INDEX" | VER="$VER" python3 -c "
import json,sys,os
ver=os.environ['VER']
d=json.load(sys.stdin)
order=['sonoma','sequoia','ventura','tahoe','monterey']
cand={}
for m in d['manifests']:
    ref=m.get('annotations',{}).get('org.opencontainers.image.ref.name','')
    if 'arm64' in ref or 'linux' in ref: continue
    tag=ref[len(ver)+1:] if ref.startswith(ver+'.') else ref
    cand[tag]=m['digest']
for t in order:
    if t in cand: print(cand[t]); break
")"
[ -n "$PLATFORM_DIGEST" ] || { echo "no x86_64 macOS libomp bottle found for $VER"; exit 1; }

# 2. platform manifest → blob (bottle tar.gz) layer digest
LAYER="$(api -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
  "https://ghcr.io/v2/homebrew/core/libomp/manifests/$PLATFORM_DIGEST" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['layers'][0]['digest'])")"

# 3. download + extract the x86_64 dylib, lipo with the local arm64 one
tmp_tgz="$(mktemp).tar.gz"; tdir="$(mktemp -d)"
api "https://ghcr.io/v2/homebrew/core/libomp/blobs/$LAYER" -o "$tmp_tgz"
tar xf "$tmp_tgz" -C "$tdir"
X86="$(find "$tdir" -name libomp.dylib | head -1)"
[ -f "$X86" ] || { echo "x86_64 libomp.dylib not in bottle"; exit 1; }
# A prior build leaves $OUT read-only (lipo inherits the Homebrew dylib's 0444 mode), which would
# make the next `lipo -create` fail with "could not write to file". Remove it first.
rm -f "$OUT"
lipo -create "$ARM_OMP" "$X86" -output "$OUT"
rm -rf "$tdir" "$tmp_tgz"

echo "libomp universal → $OUT ($(lipo -info "$OUT" | sed 's/.*: //'))"
