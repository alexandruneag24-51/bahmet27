#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRATES=(bahmet_deep bahmet_vault)
case "$(uname -s)" in
  Darwin) EXT="dylib" ;;
  MINGW*|MSYS*|CYGWIN*) EXT="dll" ;;
  *) EXT="so" ;;
esac
mkdir -p "$ROOT/priv"
for crate in "${CRATES[@]}"; do
  M="$ROOT/native/$crate/Cargo.toml"
  echo "==> cargo test ($crate)"
  cargo test --manifest-path "$M"
  echo "==> cargo build --release ($crate)"
  cargo build --release --manifest-path "$M"
  if [ "$EXT" = "dylib" ]; then
    cp "$ROOT/native/$crate/target/release/lib$crate.dylib" "$ROOT/priv/lib$crate.so"
  else
    cp "$ROOT/native/$crate/target/release/lib$crate.$EXT" "$ROOT/priv/lib$crate.$EXT"
  fi
  echo "    -> priv/lib$crate"
done
echo "==> rebar3 compile"
rebar3 compile
