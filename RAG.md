# RAG — Etapele 1 și 2

Cum devine Bahmet 27 un sistem care răspunde la întrebări din documentele tale,
fără să antreneze nimic.

> **Stare: schelet funcțional.** Puntea către Ollama și memoria vectorială
> rulează. Ce lipsește e în §6.

---

## 1. Împărțirea muncii

```
        ┌──────────────── Erlang / BEAM (Focul) ────────────────┐
        │  ființe · supervizare · răbdare · HTTP · orchestrare   │
        └───────┬───────────────────────────────┬───────────────┘
                │                               │
     bahmet_oracle (HTTP)              bahmet_recall (NIF)
                │                               │
        ┌───────▼────────┐            ┌─────────▼──────────┐
        │  Ollama / GPU  │            │  Rust / CPU        │
        │  RTX 5070      │            │                    │
        │                │            │  depozit vectori   │
        │  text → vector │            │  cosinus, top-k    │
        │  imagine+prompt│            │  zero I/O          │
        │      → răspuns │            │                    │
        └────────────────┘            └────────────────────┘
```

| Cine | Ce face | De ce acolo |
|---|---|---|
| **Ollama (GPU)** | vectorizare, inferență, viziune | singurul care are nevoie de placă |
| **Rust (CPU)** | memoria și căutarea | latență critică, aritmetică pură |
| **Erlang** | HTTP, supervizare, răbdare | e ce face BEAM cel mai bine |

### De ce HTTP-ul NU e într-un NIF

Tentația era să pui cererea către Ollama într-un NIF Rustler. Ar fi fost o
greșeală tehnică și o trădare a împărțirii pe care stă tot proiectul.

**Tehnic:** o inferență durează 5–60 de secunde. Un NIF, chiar pe planificator
murdar, ar ține ocupat un fir dintr-un bazin limitat (implicit, numărul de
nuclee) pe toată durata. Patru cereri simultane ar înfometa tot bazinul — pe
care îl împarte și criptografia. Și nu ai cum să anulezi.

**Filozofic:** Focul vorbește cu lumea, Apa gândește în tăcere. Un Rust care
dă telefoane e Apa ieșită la suprafață.

### De ce vectorizarea NU e în `candle`

Am cântărit un model de embedding încărcat în Rust prin `candle`. Ar fi
însemnat un tokenizer reimplementat, greutăți de descărcat și versionat, și o
a doua cale prin care lucrurile pot merge prost — pentru un rezultat identic
cu ce dă Ollama, pe aceeași placă.

Valoarea lui Rust în RAG nu e vectorizarea. E **căutarea**: 100.000 de bucăți
× 768 de dimensiuni = 76 de milioane de înmulțiri, la fiecare întrebare.
Acolo Rust bate BEAM cu două ordine de mărime, și e muncă pură — fără I/O,
fără așteptare, doar aritmetică peste un bloc contiguu de memorie.

---

## 2. Pornirea

```bash
# Ollama, cu suport CUDA pentru RTX 5070
curl -fsSL https://ollama.com/install.sh | sh

ollama pull llama3.1:8b        # răspunsuri în text
ollama pull llava:7b           # viziune
ollama pull nomic-embed-text   # vectorizare, 768 de dimensiuni
```

Verifică placa:

```bash
ollama run llama3.1:8b "salut" --verbose
nvidia-smi
```

Dacă `nvidia-smi` nu arată VRAM ocupat în timpul inferenței, Ollama rulează pe
procesor — de zece-douăzeci de ori mai lent. Cauza obișnuită e lipsa
driverelor CUDA în WSL.

Apoi, în proiect:

```bash
./build.sh
ERL_CRASH_DUMP_SECONDS=0 rebar3 shell
```

```erlang
bahmet_oracle:health().
%% {ok, [<<"llama3.1:8b">>, <<"llava:7b">>, <<"nomic-embed-text">>]}

bahmet_oracle:dimension().
%% {ok, 768}
```

---

## 3. Prima memorie

```erlang
{ok, _} = bahmet_memory:start_link().

{ok, Text} = file:read_file("cartea.txt"),
{ok, Count} = bahmet_memory:assimilate(<<"cartea.txt">>, Text).
%% {ok, 412}

{ok, Found} = bahmet_memory:recall(<<"ce spune despre răbdare?">>, 4).
```

`Found` e o listă de hărți cu `text`, `source` și `score`. Memoria **nu
răspunde** — își amintește. Răspunsul e treaba oracolului:

```erlang
Context = iolist_to_binary([[maps:get(text, F), "\n\n"] || F <- Found]),
Prompt = <<"Răspunde folosind DOAR textul de mai jos. Dacă nu conține "
           "răspunsul, spune că nu știi.\n\n", Context/binary,
           "\n\nÎntrebare: ce spune despre răbdare?">>,
bahmet_oracle:ask(Prompt).
```

Separarea e importantă: **cine își amintește nu e cine răspunde.** Poți schimba
modelul fără să reconstruiești memoria, și poți verifica ce a stat la baza
răspunsului fiindcă sursele vin cu el.

### Imagini

```erlang
{ok, Png} = file:read_file("schema.png"),
bahmet_oracle:see(<<"Ce arată această diagramă?">>, Png).
```

---

## 4. Ce e deja gândit

**Dimensiunea se măsoară, nu se presupune.** `bahmet_memory:init/1` cheamă
`bahmet_oracle:dimension/0` și deschide memoria pe forma reală. Un sistem care
presupune 768 și primește 1024 nu eșuează zgomotos — umple memoria cu vectori
de formă greșită și întoarce vecini absurzi, luni la rând.

**Normalizarea se face o dată, la inserare.** Cosinusul devine un simplu produs
scalar la căutare. O împărțire acum economisește o rădăcină pătrată per
amintire, la fiecare întrebare, pentru totdeauna.

**Vectorii stau într-un bloc contiguu**, nu în `Vec<Vec<f32>>`. Procesorul
citește secvențial și preîncarcă singur; cu vectori separați, fiecare
comparație ar fi un salt în altă zonă de memorie.

**Asimilarea se oprește la primul eșec.** Alternativa ar lăsa o memorie pe
jumătate umplută, care răspunde plauzibil dar incomplet.

**Uitarea șterge și vectorul.** Un vector marcat ca șters, dar rămas în
memorie, e o promisiune pe care sistemul nu o ține.

---

## 5. Ce nu e încă gândit

**O ființă în inferență e o ființă surdă.** Cât timp un `gen_server` așteaptă
răspunsul, nu-și citește cutia poștală. Nu e un bug — mesajele se adună — dar
`patience` unei ființe care cheamă oracolul trebuie să fie mai mare decât
termenul inferenței. Altfel ai declarat o răbdare pe care sistemul nu o poate
respecta.

Forma corectă, pentru mai târziu: coborârea în Adânc se face într-un proces
separat, monitorizat, iar ființa rămâne prezentă în cerc cât timp coboară. E
și mai frumos filozofic — dar complică generatorul, deci merită abia după ce
varianta simplă își arată limitele.

**Memoria nu se persistă încă.** Trăiește în RAM și dispare la repornire.
Pentru zeci de mii de bucăți, reasimilarea durează minute; peste, ai nevoie de
salvare pe disc.

**Împărțirea în bucăți e naivă.** Paragrafe cu suprapunere. Merge surprinzător
de bine pe proză; pe cod, tabele sau poezie, mai puțin.

**Nu există reordonare.** Cosinusul e o măsură bună, nu excelentă. Un
*cross-encoder* peste primii 20 de candidați ar îmbunătăți vizibil calitatea.

---

## 6. Ce urmează

| Pas | Efort | Valoare |
|---|---|---|
| persistarea memoriei pe disc | mic | mare — nu mai reasimilezi la fiecare pornire |
| ingestie din PDF și HTML | mic | mare — cărțile tale nu sunt `.txt` |
| coborâre asincronă în Adânc | mediu | ființe care rămân prezente |
| reordonare cu cross-encoder | mediu | răspunsuri vizibil mai bune |
| Qdrant sau LanceDB | mediu | abia peste ~500.000 de bucăți |
| verbele DSL (Etapa 4) | mare | limbajul descrie și fluxul RAG |

Peste jumătate de milion de bucăți, depozitul din RAM devine problema: 500.000
× 768 × 4 octeți ≈ 1,5 GB doar vectorii, plus căutare liniară la fiecare
întrebare. Atunci vrei un index aproximativ (HNSW) și un serviciu dedicat.

Până acolo, un `Vec<f32>` contiguu e mai rapid decât aproape orice bază de date
vectorială — fiindcă nu are rețea, nu are serializare, și nu are un al doilea
proces de supravegheat.

---

## 7. Codurile — memoria comprimată (cifre cisterciene)

Fiecare vector e tăiat în felii; fiecare felie e înlocuită de adresa celei
mai apropiate forme dintr-un tabel învățat (cuantizare pe produs). Codul are
patru părți, ca o cifră cisterciană cu patru cadrane, și se poate desena ca
atare: `bahmet_recall:glyph(Code)` întoarce un SVG.

```erlang
Coded = bahmet_recall:compress(Memory, 4, 256),     % 4 părți × 256 de forme
bahmet_recall:recall_coded(Coded, Query, 10),
bahmet_recall:glyph(bahmet_recall:code_of(Coded, Id)).
```

Măsurat cu `cargo run --release --example pq_bench` (date **sintetice**,
20.000 de amintiri × 768, 200 de întrebări, 4 nuclee):

| Variantă | Memorie | Învățare | Per întrebare | recall@10 |
|---|---|---|---|---|
| vectori întregi (exact) | 58,6 MB | – | 10,8 ms | 100% |
| 4 × 256 | **846 KB** | 6,6 s | **0,33 ms** | 48% |
| 4 × 256 + reordonare exactă a primilor 100 | 846 KB + vectori pe disc | – | 0,44 ms | **100%** |
| 4 × 10.000 | 29,4 MB | 181 s | 3,9 ms | 69% |
| 4 × 10.000 + reordonare | 29,4 MB + vectori pe disc | – | 4,0 ms | 100% |
| 16 × 256 | 1,1 MB | 5,2 s | 0,40 ms | 55% |

Ce spun cifrele:

- **4 × 256 câștigă.** De ~70 de ori mai puțină memorie, de ~30 de ori mai
  rapid. Singur, găsește doar jumătate din vecinii exacți — dar cei 10
  adevărați sunt mereu în primii 100, deci o reordonare exactă a acelor 100
  aduce precizia la 100% cu 0,1 ms în plus.
- **4 × 10.000 nu merită.** Tabelele lui ocupă cât jumătate din vectorii
  întregi, învățarea durează de ~27 de ori mai mult, iar căutarea e de ~12
  ori mai lentă decât 4 × 256 — pentru un câștig de precizie pe care
  reordonarea îl dă oricum.
- Datele sunt sintetice. Pe o memorie reală, rulează
  `cargo run --release --example pq_bench -- memorie.bhm1`, după
  `file:write_file("memorie.bhm1", bahmet_recall:snapshot(M))`.

Pasul următor firesc: vectorii întregi pe disc (mmap), codurile în RAM, și
reordonarea legată în `bahmet_memory`.
