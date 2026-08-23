#!/usr/bin/env sh
# Install a tdweb dist (TDLib compiled to WebAssembly) into web/vendor/tdweb/.
#
#   web/scripts/install-tdweb.sh <dist-dir> [--public-path /vendor/tdweb/]
#
# <dist-dir> is the `dist/` folder produced either by web/tdweb-build/Dockerfile
# (self-built from tdlib/td master, preferred) or by unpacking a registry
# tarball (`npm pack @aefen/tdweb@1.8.49` → package/dist, fallback).
#
# What it does:
#   1. wipes web/vendor/tdweb/ and copies tdweb.js, every *.worker.js chunk and
#      every *.wasm from <dist-dir> (plus package.json / TD_COMMIT if present,
#      for provenance);
#   2. patches the webpack publicPath inside tdweb.js from "" to
#      "/vendor/tdweb/". tdweb resolves its Web Worker relative to the PAGE
#      url, not the script url, so without this the worker 404s whenever the
#      page is anywhere but the dist directory. The site lives at the origin
#      root, hence the absolute path. Verified required (see web/README.md).
set -eu

if [ $# -lt 1 ]; then
  echo "usage: $0 <dist-dir> [--public-path /vendor/tdweb/]" >&2
  exit 2
fi

DIST="$1"
PUBLIC_PATH="/vendor/tdweb/"
if [ "${2:-}" = "--public-path" ] && [ -n "${3:-}" ]; then
  PUBLIC_PATH="$3"
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
WEB="$(cd "$HERE/.." && pwd)"
OUT="$WEB/vendor/tdweb"

if [ ! -f "$DIST/tdweb.js" ]; then
  echo "install-tdweb: $DIST/tdweb.js not found" >&2
  exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT"
cp "$DIST/tdweb.js" "$OUT/tdweb.js"
for f in "$DIST"/*.worker.js "$DIST"/*.wasm "$DIST"/package.json "$DIST"/TD_COMMIT; do
  [ -f "$f" ] && cp "$f" "$OUT/"
done

# webpack publicPath patch (BSD and GNU sed both accept -i with a backup suffix)
if grep -q '__webpack_require__.p = "";' "$OUT/tdweb.js"; then
  sed -i.bak "s#__webpack_require__.p = \"\";#__webpack_require__.p = \"$PUBLIC_PATH\";#" "$OUT/tdweb.js"
  rm -f "$OUT/tdweb.js.bak"
  echo "install-tdweb: patched publicPath → $PUBLIC_PATH"
elif grep -q "__webpack_require__.p = \"$PUBLIC_PATH\";" "$OUT/tdweb.js"; then
  echo "install-tdweb: publicPath already $PUBLIC_PATH"
else
  echo "install-tdweb: could not find the webpack publicPath line in tdweb.js; the worker may not resolve" >&2
  exit 1
fi

VERSION="unknown"
if [ -f "$OUT/package.json" ]; then
  VERSION="$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$OUT/package.json" | head -1)"
fi
{
  echo "tdweb dist installed $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "source: $DIST"
  echo "package version: $VERSION"
  [ -f "$OUT/TD_COMMIT" ] && echo "td commit: $(cat "$OUT/TD_COMMIT")"
  echo "publicPath: $PUBLIC_PATH"
} > "$OUT/PROVENANCE.txt"

ls -la "$OUT"
