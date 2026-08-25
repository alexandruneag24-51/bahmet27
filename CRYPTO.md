# Bahmet 27 — Arhitectura criptografică

> **Stare: schelet de proiectare, NU produs de securitate.**
> Acest cod nu a fost auditat, nu a fost supus unui pentest și nu a fost
> validat FIPS. Nu proteja date reale cu el în forma actuală. Citește
> secțiunea „Ce NU face" înainte de orice altceva.

---

## 1. Principiul central: frontiera de custodie

```
        ┌─────────────────── BEAM (Focul, exteriorul) ───────────────────┐
        │                                                                 │
        │   bahmet_keyring        bahmet_vault        bahmet_sentinel     │
        │   orchestrează          comandă             observă             │
        │        │                    │                    │              │
        │        └────── #Ref<> opac ─┴──── doar metadate ──┘              │
        │                        │                                        │
        └────────────────────────┼────────────────────────────────────────┘
                                 │  frontiera de custodie
        ┌────────────────────────┼────────────────────────────────────────┐
        │                        ▼                                        │
        │   KeyHandle { material: Zeroizing<[u8;32]> }                    │
        │                                                                  │
        │              Rust (Apa, umbra) — cheile trăiesc AICI            │
        └──────────────────────────────────────────────────────────────────┘
```

**Regula:** nicio funcție din `bahmet_vault` nu întoarce material de cheie.
Nu există `export_key`, nu există `key_bytes`, nu există `dump`. Absența lor
nu e o omisiune — e mecanismul.

### De ce contează pe BEAM în mod special

| Hazard | Consecință | Mitigare |
|---|---|---|
| Binarele > 64 B sunt off-heap, numărate prin referințe | O cheie poate exista în N copii pe care nu le poți urmări | Cheia nu intră niciodată ca termen |
| GC nedeterminist | Nu poți ști când se eliberează memoria unui secret | `Zeroizing` în Rust, unde `Drop` e determinist |
| `erl_crash.dump` conține heap-urile proceselor | Un crash scrie secretele pe disc | `ERL_CRASH_DUMP_SECONDS=0` |
| `sys:get_state`, error logger | Starea unui gen_server se tipărește la crash | `format_status/1` cu redactare |
| Distribuția Erlang e în clar implicit | Termenii circulă necriptați între noduri | TLS pe distribuție, sau nod unic |

Pornirea corectă:

```bash
ERL_CRASH_DUMP_SECONDS=0 ERL_CRASH_DUMP=/dev/null rebar3 shell
```

---

## 2. Alegeri de algoritmi și motivele lor

### Cifrare simetrică: XChaCha20-Poly1305 implicit

Nu AES-256-GCM implicit, deși e mai cunoscut. Motivul e **nonce-ul**:

| Cifru | Nonce | Limită practică cu nonce aleator |
|---|---|---|
| AES-256-GCM | 96 biți | ~2³² mesaje/cheie înainte de risc de coliziune |
| ChaCha20-Poly1305 | 96 biți | idem |
| **XChaCha20-Poly1305** | **192 biți** | practic nelimitat |

Reutilizarea unui nonce cu GCM este **catastrofală**: pierzi confidențialitatea
*și* autenticitatea, și permite recuperarea cheii de autentificare. Cu 192 de
biți, nonce-urile aleatoare nu se ciocnesc niciodată în practică, deci elimini
o clasă întreagă de greșeli fără să te bazezi pe disciplina programatorului.

AES-256-GCM rămâne disponibil pentru interoperabilitate și pentru mașinile cu
AES-NI unde contează debitul brut.

### Post-cuantic: hibrid, niciodată pur

NIST a standardizat ML-KEM (FIPS 203), ML-DSA (FIPS 204) și SLH-DSA (FIPS 205).
Dar implementările PQC sunt tinere, iar criptanaliza lor e la început.

**Construcția corectă e hibridă:** X25519 ‖ ML-KEM-768, cu secretele combinate
printr-un KDF. Sistemul rezistă dacă *măcar una* din cele două scheme ține.
Așa fac Signal (PQXDH), Cloudflare și TLS hibrid.

Recomandare de crate: `libcrux-ml-kem` — este **verificat formal**, ceea ce se
potrivește cu perfecționismul cerut de profil mai bine decât orice comentariu.

Tensiune reală de semnalat: hibridul complică validarea FIPS, fiindcă partea
X25519 nu e un KEM aprobat de sine stătător. Nu poți avea și PQC hibrid, și
FIPS curat, fără muncă suplimentară.

### Entropie

```rust
OsRng.fill_bytes(&mut buffer)   // getrandom(2) / BCryptGenRandom
```

Atât. Kernelul amestecă deja RDRAND, jitter de întreruperi și zgomot hardware,
apoi trece totul printr-un CSPRNG. `bahmet_entropy` verifică la pornire că
sursa răspunde și **refuză să pornească sistemul** dacă nu — vezi §4.

Ce NU facem: rezervoare proprii de entropie, RDRAND direct, amestecarea cu
timestamp-uri sau PID-uri. Fiecare dintre acestea slăbește rezultatul.

---

## 3. Managementul cheilor: cifrare cu plic

```
  Cheia rădăcină (KEK)  ──── injectată la pornire, din exterior
         │                   NU se persistă niciodată local
         │ împachetează
         ▼
  DEK per obiect  ──── generată aleator, unică per obiect
         │ cifrează
         ▼
  Datele
```

**Rotația** înseamnă generarea unui KEK nou și *reîmpachetarea DEK-urilor* —
operație de ordinul kilobyte-ilor. Datele în vrac nu se ating. Rotația unui
terabyte durează secunde.

**Distrugerea sigură** e crypto-shredding: distrugi KEK-ul, iar toate DEK-urile
împachetate cu el devine imposibil de desfăcut. Datele devin zgomot fără a
atinge un singur octet din ele. Elegant — și singura ștergere care funcționează
pe medii cu wear-leveling, backup-uri și replici.

**Cheia rădăcină nu se persistă.** `bahmet_keyring` refuză să pornească fără
una injectată de la un KMS extern (AWS KMS, Vault, HSM PKCS#11) sau de operator
la boot. A o scrie pe disc lângă ciphertext anulează întreg exercițiul.

---

## 4. Ce vede santinela — și ce nu

`bahmet_sentinel` detectează anomalii folosind **exclusiv metadate**:

| Vede | Nu vede |
|---|---|
| rata de cereri `unseal` per cheie | plaintext |
| raportul eșecuri/succese | material de cheie |
| distribuția intervalelor între cereri | conținutul AAD |
| vârsta cheii la momentul accesului | identitatea obiectelor |

Proprietatea e **structurală, nu politică**: procesul santinelă nu primește
niciodată un `#Ref<>` de cheie și nu are în lista lui de apeluri nicio funcție
care întoarce plaintext. Nu „nu are voie" — nu poate.

Santinela reutilizează `bahmet_deep:intuit/2`: vectorul de trăsături intră,
distribuția de probabilitate iese, iar entropia devine scor de anomalie.
Aceasta e „intuiția Apei Yin" din profil, aplicată la ceva măsurabil.

**Constrângere de proiectare:** santinela **raportează, nu execută**. Un
detector care poate revoca chei singur este un vector de auto-DoS: un atacator
care declanșează intenționat alarme îți oprește sistemul. Acțiunile distructive
cer confirmare umană.

---

## 5. Canale laterale

Implementat:

- Comparații în timp constant (`subtle::ConstantTimeEq`) — niciodată `==` pe secrete
- Ștergere la eliberare (`zeroize`), cu scrieri volatile pe care optimizatorul nu le poate elimina
- **Un singur atom de eroare la decriptare.** `unseal` întoarce `decrypt_failed` fie că a fost cheie greșită, ciphertext corupt sau AAD nepotrivit. Erori distincte ar fi un oracol.
- NIF-urile grele pe `DirtyCpu`, deci timpul de execuție nu se corelează cu încărcarea planificatorului

Neimplementat, și nu poate fi în software pur:

- Rezistență la analiza consumului de putere sau la emisii electromagnetice
- Atacuri de tip cache-timing pe AES fără AES-NI (folosește ChaCha20 acolo)
- Spectre / Meltdown și rudele lor
- Un adversar cu acces fizic la mașină

---

## 6. Ce NU face acest cod

Citește lista asta ca pe un contract.

1. **Nu e validat FIPS 140-3** și nu poate deveni prin modificări de cod.
2. **Nu e auditat.** Cod criptografic nerevizuit trebuie presupus rupt.
3. **Nu implementează PQC** încă. `hybrid_kem` e o schiță marcată ca atare.
4. **Nu gestionează cheia rădăcină.** Presupune un KMS/HSM extern.
5. **Nu protejează plaintext-ul după `unseal`.** Odată în BEAM, e supus tuturor
   hazardelor din §1. Minimizează-i durata de viață.
6. **Nu apără împotriva unui atacator care rulează cod pe aceeași mașină.**
   Cine poate atașa un debugger la procesul BEAM citește tot.
7. **Nu are protecție anti-replay** la nivel de protocol. AAD trebuie să conțină
   un contor sau un timestamp, în funcție de aplicație.

## 7. Înainte de producție

- [ ] Audit criptografic extern
- [ ] `cargo audit` și `cargo deny` în CI
- [ ] Fuzzing pe fiecare NIF (`cargo fuzz`) — intrările vin de la BEAM și trebuie tratate ca ostile
- [ ] Vectori de test cunoscuți (RFC 8439 pentru ChaCha20-Poly1305)
- [ ] KMS/HSM real pentru cheia rădăcină
- [ ] `ERL_CRASH_DUMP_SECONDS=0` în toate mediile
- [ ] TLS pe distribuția Erlang, sau nod unic
- [ ] Jurnal de audit append-only, separat de jurnalul aplicației
- [ ] Procedură de răspuns la incident pentru compromiterea unei chei
