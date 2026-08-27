#!/usr/bin/env bash
# Construieste ambele crate-uri native si le aseaza in priv/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRATES=(bahmet_deep bahmet_vault bahmet_recall)

case "$(uname -s)" in
  Darwin) EXT="dylib" ;;
  MINGW*|MSYS*|CYGWIN*) EXT="dll" ;;
  *) EXT="so" ;;
esac

mkdir -p "$ROOT/priv"

for crate in "${CRATES[@]}"; do
  MANIFEST="$ROOT/native/$crate/Cargo.toml"

  echo "==> cargo test ($crate)"
  cargo test --manifest-path "$MANIFEST"

  echo "==> cargo build --release ($crate)"
  cargo build --release --manifest-path "$MANIFEST"

  # Pe macOS, BEAM cauta .so chiar daca cargo produce .dylib.
  if [ "$EXT" = "dylib" ]; then
    cp "$ROOT/native/$crate/target/release/lib$crate.dylib" "$ROOT/priv/lib$crate.so"
  else
    cp "$ROOT/native/$crate/target/release/lib$crate.$EXT" "$ROOT/priv/lib$crate.$EXT"
  fi
  echo "    -> priv/lib$crate"
done

echo "==> rebar3 compile"
rebar3 compile

cat <<'MSG'

Gata. Porneste asa (NU uita variabilele):

  export BAHMET_ROOT_KEY=$(openssl rand -hex 32)
  ERL_CRASH_DUMP_SECONDS=0 rebar3 shell

Apoi in shell:

  bahmet_smoke:run().     % 12 probe criptografice
  bahmet_smoke:tree().    % arborele de supervizare

MSG
