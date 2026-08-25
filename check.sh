#!/usr/bin/env bash
# check.sh -- totul, de jos in sus.
#
#   19 invariante in Rust   (cargo test, fara BEAM)
#   29 invariante in Erlang (Common Test, cu BEAM)
#
# Ordinea conteaza: esecurile din Rust sunt mai ieftin de diagnosticat decat
# cele din CT, asa ca le vrem primele.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

# Radacina de test. Daca ai deja una in mediu, o pastram.
if [ -z "${BAHMET_ROOT_KEY:-}" ]; then
    if command -v openssl >/dev/null 2>&1; then
        export BAHMET_ROOT_KEY="$(openssl rand -hex 32)"
    else
        export BAHMET_ROOT_KEY="$(head -c32 /dev/urandom | xxd -p -c64)"
    fi
    echo "==> BAHMET_ROOT_KEY generat pentru aceasta rulare"
fi

# Fara dump-uri: un crash in teste ar scrie heap-urile proceselor pe disc,
# inclusiv orice a trecut prin ele.
export ERL_CRASH_DUMP_SECONDS=0

echo
echo "═══ 1. Miezul (Rust, fara masina virtuala) ═══"
./build.sh

echo
echo "═══ 2. Sistemul (Common Test, cu masina virtuala) ═══"
rebar3 ct

echo
echo "Totul trece. Raport HTML: _build/test/logs/index.html"
