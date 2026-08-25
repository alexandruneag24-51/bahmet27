#!/usr/bin/env bash
# sync.sh — aseaza fisierele descarcate in structura proiectului.
#
# Le identifica dupa CONTINUT, nu dupa nume, fiindca Windows redenumeste
# descarcarile duplicate in "lib (1).rs", "Cargo (2).toml" etc. Numele nu
# mai spune nimic; interiorul spune totul.
#
# Ruleaza din radacina proiectului:  bash sync.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

# Locurile in care Windows pune descarcarile.
LOOK=()
for d in "/mnt/c/Users/$USER/Downloads" "/mnt/c/Users/$USER/Desktop" \
         /mnt/c/Users/*/Downloads /mnt/c/Users/*/Desktop "$HOME/Downloads"; do
    [ -d "$d" ] && LOOK+=("$d")
done

if [ ${#LOOK[@]} -eq 0 ]; then
    echo "Nu gasesc niciun director de descarcari. Editeaza LOOK in script."
    exit 1
fi

mkdir -p src dsl native/bahmet_deep/src native/bahmet_vault/src

placed=0
say() { echo "  -> $1"; placed=$((placed + 1)); }

# ── Module Erlang ───────────────────────────────────────────────────
# Numele adevarat sta in -module(...). Imun la redenumirile Windows.
while IFS= read -r f; do
    m=$(grep -m1 -oP '^-module\(\s*\K[a-z_0-9]+' "$f" 2>/dev/null)
    if [ -n "$m" ]; then
        cp "$f" "src/$m.erl" && say "src/$m.erl"
    fi
done < <(find "${LOOK[@]}" -maxdepth 2 -name '*.erl' 2>/dev/null)

# ── .app.src ────────────────────────────────────────────────────────
while IFS= read -r f; do
    cp "$f" src/bahmet.app.src && say "src/bahmet.app.src"
done < <(find "${LOOK[@]}" -maxdepth 2 -name '*.app.src' 2>/dev/null)

# ── Surse Rust: distinse prin numele crate-ului din init! ───────────
while IFS= read -r f; do
    if grep -q 'bahmet_vault' "$f"; then
        cp "$f" native/bahmet_vault/src/lib.rs && say "native/bahmet_vault/src/lib.rs"
    elif grep -q 'bahmet_deep' "$f"; then
        cp "$f" native/bahmet_deep/src/lib.rs && say "native/bahmet_deep/src/lib.rs"
    fi
done < <(find "${LOOK[@]}" -maxdepth 2 -name 'lib*.rs' 2>/dev/null)

# ── Manifeste Cargo: distinse prin name = "..." ─────────────────────
while IFS= read -r f; do
    if grep -q 'name *= *"bahmet_vault"' "$f"; then
        cp "$f" native/bahmet_vault/Cargo.toml && say "native/bahmet_vault/Cargo.toml"
    elif grep -q 'name *= *"bahmet_deep"' "$f"; then
        cp "$f" native/bahmet_deep/Cargo.toml && say "native/bahmet_deep/Cargo.toml"
    fi
done < <(find "${LOOK[@]}" -maxdepth 2 -name 'Cargo*.toml' 2>/dev/null)

# ── DSL ─────────────────────────────────────────────────────────────
while IFS= read -r f; do
    case "$(basename "$f")" in
        vault*)        cp "$f" dsl/vault.b27 && say "dsl/vault.b27" ;;
        contemplation*) cp "$f" dsl/contemplation.b27 && say "dsl/contemplation.b27" ;;
    esac
done < <(find "${LOOK[@]}" -maxdepth 2 -name '*.b27' 2>/dev/null)

# ── Documente ───────────────────────────────────────────────────────
while IFS= read -r f; do
    case "$(basename "$f")" in
        GRAMMAR*) cp "$f" dsl/GRAMMAR.md && say "dsl/GRAMMAR.md" ;;
        PROFILE*) cp "$f" dsl/PROFILE.md && say "dsl/PROFILE.md" ;;
        CRYPTO*)  cp "$f" CRYPTO.md      && say "CRYPTO.md" ;;
        README*)  cp "$f" README.md      && say "README.md" ;;
    esac
done < <(find "${LOOK[@]}" -maxdepth 2 -name '*.md' 2>/dev/null)

# ── build.sh: il vrem pe cel nou, care stie ambele crate-uri ────────
while IFS= read -r f; do
    if grep -q 'CRATES=' "$f"; then
        cp "$f" build.sh && chmod +x build.sh && say "build.sh (versiunea cu doua crate-uri)"
    fi
done < <(find "${LOOK[@]}" -maxdepth 2 -name 'build*.sh' 2>/dev/null)

# ── rebar.config ────────────────────────────────────────────────────
while IFS= read -r f; do
    cp "$f" rebar.config && say "rebar.config"
done < <(find "${LOOK[@]}" -maxdepth 2 -name 'rebar*.config' 2>/dev/null)

echo
echo "$placed fisiere asezate."
echo
echo "Verificare — ar trebui sa vezi 14 module .erl si 2 crate-uri:"
find . -path ./native/'*'/target -prune -o -type f \
     \( -name '*.erl' -o -name '*.rs' -o -name '*.toml' -o -name '*.b27' \) -print \
     | sort
