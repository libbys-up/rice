#!/bin/sh
# Puts the Curry front end rice needs at bin/curry-frontend. Used by
# `make frontend`. In order, the first that works:
#
#   1. bin/curry-frontend is already there, at the right version.
#   2. $RICE_FRONTEND, or a front end on $PATH (curry-frontend,
#      kics2-frontend, pakcs-frontend), at the right version: link to it.
#   3. Download the prebuilt binary for this platform from rice's GitHub
#      releases, if tools/frontend-checksums.txt has its checksum, and
#      check it.
#   4. Build it from the frontend/ submodule with Stack or cabal.
#
# With --source, it goes straight to 4.
#
# Usage: tools/get-frontend.sh [--source]
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=3.1.0
BIN="$ROOT/bin"
TARGET="$BIN/curry-frontend"
RELEASES="https://github.com/libbys-up/rice/releases/download/frontend-$VERSION"
SOURCE=0
[ "${1:-}" = "--source" ] && SOURCE=1

# Does front end $1 report version $VERSION?
right_version() {
  [ -x "$1" ] || return 1
  "$1" --version 2>/dev/null | grep -q "version $VERSION\$"
}

mkdir -p "$BIN"

if [ $SOURCE -eq 0 ]; then
  # 1.
  if right_version "$TARGET"; then
    echo "Using the front end in bin/ (version $VERSION)."
    exit 0
  fi

  # 2.
  candidates="${RICE_FRONTEND:-}"
  for name in curry-frontend kics2-frontend pakcs-frontend; do
    found="$(command -v "$name" 2>/dev/null || true)"
    candidates="$candidates $found"
  done
  for fe in $candidates; do
    if right_version "$fe"; then
      ln -sf "$fe" "$TARGET"
      echo "Using the front end at $fe (version $VERSION)."
      exit 0
    fi
  done

  # 3.
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"
  [ "$arch" = aarch64 ] && arch=arm64
  file="curry-frontend-$VERSION-$os-$arch.gz"
  sum="$(sed -n "s/^\([0-9a-f]*\)  $file\$/\1/p" "$ROOT/tools/frontend-checksums.txt" 2>/dev/null || true)"
  if [ -n "$sum" ] && command -v curl >/dev/null 2>&1; then
    echo "Downloading the front end for $os-$arch."
    tmp="$(mktemp -d)"
    if curl -fsSL -o "$tmp/$file" "$RELEASES/$file"; then
      if command -v sha256sum >/dev/null 2>&1; then
        got="$(sha256sum "$tmp/$file" | cut -d' ' -f1)"
      else
        got="$(shasum -a 256 "$tmp/$file" | cut -d' ' -f1)"
      fi
      if [ "$got" = "$sum" ]; then
        gunzip -c "$tmp/$file" > "$TARGET"
        chmod +x "$TARGET"
        rm -rf "$tmp"
        if right_version "$TARGET"; then
          echo "Installed the front end in bin/ (version $VERSION)."
          exit 0
        fi
        echo "The downloaded front end doesn't run here; building it instead." >&2
        rm -f "$TARGET"
      else
        echo "The downloaded front end's checksum is wrong; building it instead." >&2
        rm -rf "$tmp"
      fi
    else
      echo "Couldn't download the front end; building it instead." >&2
      rm -rf "$tmp"
    fi
  else
    echo "No prebuilt front end for $os-$arch; building it from source."
  fi
fi

# 4.
if [ ! -f "$ROOT/frontend/curry-frontend.cabal" ]; then
  if [ -d "$ROOT/.git" ]; then
    git -C "$ROOT" submodule update --init frontend
  else
    echo "No frontend/ source to build the front end from. Install a Curry" >&2
    echo "system with front end $VERSION (KiCS2 or PAKCS), or set" >&2
    echo "RICE_FRONTEND to a curry-frontend $VERSION executable." >&2
    exit 1
  fi
fi
cd "$ROOT/frontend"
if command -v stack >/dev/null 2>&1; then
  stack install --local-bin-path "$BIN"
elif command -v cabal >/dev/null 2>&1; then
  cabal install exe:curry-frontend --installdir="$BIN" \
        --install-method=copy --overwrite-policy=always
else
  echo "Building the front end needs Haskell Stack or cabal. Or install a" >&2
  echo "Curry system with front end $VERSION (KiCS2 or PAKCS), or set" >&2
  echo "RICE_FRONTEND to a curry-frontend $VERSION executable." >&2
  exit 1
fi
right_version "$TARGET" || { echo "Built a front end, but it isn't version $VERSION." >&2; exit 1; }
echo "Built the front end in bin/ (version $VERSION)."
