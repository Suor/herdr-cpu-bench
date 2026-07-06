#!/usr/bin/env bash
# Build a herdr variant from the bundled herdr/ submodule into bin/herdr-<label>.
# Requires cargo + zig 0.15.x. If zig isn't on PATH, pass it: ZIG=/path/to/zig ./build.sh ...
# Usage: ./build.sh <git-ref> <label>
#   ./build.sh master     master   -> bin/herdr-master   (baseline)
#   ./build.sh proper-fix fixed    -> bin/herdr-fixed     (Suor's fix)
set -eu
REF="${1:?usage: ./build.sh <git-ref> <label>}"
LABEL="${2:?usage: ./build.sh <git-ref> <label>}"
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$PROJ/bin"
git -C "$PROJ/herdr" checkout "$REF"
( cd "$PROJ/herdr" && cargo build --release --bin herdr )   # ZIG is inherited from the environment
cp "$PROJ/herdr/target/release/herdr" "$PROJ/bin/herdr-$LABEL"
echo "[build] bin/herdr-$LABEL  <-  herdr@$REF"
