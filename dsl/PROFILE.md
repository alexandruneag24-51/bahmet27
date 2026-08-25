# Bahmet 27 — Profilul ca generator de constrângeri

Vizionarul Strategic. Cal de Foc / Maimuță de Foc / Cocoș de Apă. Atitudine 8,
Ziua 27, Calea Vieții 9.

## Cum tratez acest document

Profilul e folosit aici ca **vocabular de proiectare**, nu ca afirmație despre
cauzalitate. Întrebarea la care răspund la fiecare linie nu e „e adevărată
astrologia?", ci „constrângerea pe care o generează această trăsătură produce
inginerie mai bună decât absența ei?".

De cele mai multe ori, da — fiindcă profilul cere lucruri aflate în tensiune
(autoritate *și* egalitate, viteză *și* perfecțiune, expunere *și* umbră), iar
tensiunea forțează decizii explicite acolo unde altfel ar fi apărut valori
implicite. Unde profilul cere ceva care ar fi inginerie proastă, o spun și
rezolv altfel. Sunt trei astfel de locuri, marcate mai jos.

---

## 1. Exteriorul de Foc — Erlang

| Trăsătură | Mecanism | Ce impune |
|---|---|---|
| **Cal de Foc** (an) — prezență, viteză, control | Arbori de supervizare | Autoritate reală: pornire, oprire, politică de repornire. Copilul nu negociază. |
| **Atitudine 8** — liderul executiv | `command` doar pe muchii de supervizare | Directiva e legală descendent. Între egali, nu există sintaxă pentru ea. |
| **Maimuță de Foc** (lună) — inventivitate în rețea | `orchestrate`, `mobilize` | Coordonare declarativă, concurență fără lacăte. |

### Corecție #1 — domeniul autorității

Profilul cere „control absolut asupra resurselor". În OTP, supervizorul e
autoritar asupra **ciclului de viață**, nu asupra **muncii**. Nu știe — și nu
are voie să știe — ce calculează copiii lui.

Un control care ar include și conținutul ar transforma supervizorul în
coordonator, adică exact gâtuirea pe care arhitectura o evită. Autoritatea
rămâne absolută; domeniul ei e mărginit la existență.

### Corecție #2 — viteza Calului de Foc are un plafon

Focul cere execuție rapidă. Dar în stratul criptografic, `bahmet_keyring` are
`intensity => 2, period => 3600` — toleranță aproape zero pe o fereastră de o
oră. Un inel de chei care cade de două ori într-o oră **nu** trebuie repornit
a treia oară; trebuie escaladat.

Aici Focul e deliberat înfrânat de 9. Un sistem de chei care reîncearcă la
nesfârșit e un sistem care ascunde un atac în zgomotul propriei rezistențe.

---

## 2. Interiorul de Apă — Rust

| Trăsătură | Mecanism | Ce impune |
|---|---|---|
| **Cocoș de Apă** (zi) — perfecționism, detaliu | Borrow-checker, `chunks_exact`, zero `unsafe` | Ieșirea din matrice e nereprezentabilă, nu doar improbabilă. |
| **Ziua 27** — consilierul intuitiv (2 = sensibilitate, 7 = analiză) | Rețea + entropie raportată | Modelul își declară îndoiala. `coherence` e cinstea numerică. |
| **Apa Yin** — ce nu se arată | `ZeroizeOnDrop`, mânere opace | Secretele nu traversează niciodată granița către Erlang. |

### Convergența care contează

Cerința simbolică („Rust rulează în umbră") și cerința de securitate #4
(zero-knowledge) produc **aceeași** decizie tehnică, din motive complet
independente.

Motivul tehnic: pe BEAM nu poți șterge fiabil un secret din memorie. GC-ul e
nedeterminist, binarele peste 64 de octeți trăiesc pe un heap partajat prin
numărare de referințe, iar copierea între procese proliferează necontrolat.

Deci: **nicio cheie și niciun plaintext ca termen Erlang, niciodată.** Erlang
primește `#Ref<...>` opace. Chiar și rezultatul decriptării e un mâner. O
singură funcție materializează octeți — `reveal` — și fiecare apel e numărat.

Umbra nu e metaforă. E limita de securitate.

---

## 3. Calea Vieții 9 — Supraveghetorul Global

| Trăsătură | Mecanism |
|---|---|
| **Generozitate** | `absolve` — contoarele de eroare se sting în timp, nu se acumulează la nesfârșit |
| **Toleranță** | `intensity`/`period` — greșeala e permisă, tiparul de greșeli nu |
| **Viziune globală** | `rest_for_one` — ordinea copiilor e graful de dependență |
| **A lăsa mediul mai bun** | `bequeath` — starea salvabilă trece la succesor la repornire |
| **Umanitarism** | Santinela pornește **prima** și cade **ultima** |

### Ordinea din `bahmet_kms_sup` — martorul supraviețuiește celui privit

`bahmet_sentinel` e primul copil, `bahmet_keyring` al doilea. Sub `rest_for_one`,
o cădere a inelului de chei **nu** atinge santinela. Jurnalul de audit
supraviețuiește exact evenimentului care îl face necesar.

Dacă ordinea ar fi inversă, un atacator care provoacă o cădere a inelului ar
șterge, gratuit, urma propriului atac.

### Ordinea din `bahmet_sup` — securitatea e temelia temeliei

```
bahmet_sup  (rest_for_one)
├── bahmet_kms_sup      ← PRIMUL: limita de securitate
│   ├── bahmet_sentinel      martorul
│   └── bahmet_keyring       cheile
├── bahmet_ground            temelia de calcul
├── bahmet_commons           bunul comun
└── bahmet_council_sup       adunarea
```

Stratul de calcul nu are voie să pornească înaintea limitei de securitate. Sub
`rest_for_one`, o cădere a KMS-ului refondează **tot** ce urmează — corect,
fiindcă dacă limita de securitate a cedat, nimic din aval nu mai e demn de
încredere.

---

## 4. Cele trei registre de vocabular

### Registrul Focului — extern, imperativ (8 / Cal de Foc)

| Cuvânt | Sens | Restricție |
|---|---|---|
| `command` | directivă | **doar descendent, pe muchie de supervizare** |
| `orchestrate` | flux declarativ | — |
| `mobilize` | naștere în cohortă | doar într-un `gathering` |
| `enforce` | politică | evaluată la compilare |
| `revoke` | distrugere de autoritate sau cheie | ireversibil |
| `witness` | eveniment de audit | metadate exclusiv |

### Registrul Apei — intern, intuitiv (27 / Cocoș de Apă)

| Cuvânt | Sens | Restricție |
|---|---|---|
| `intuit` | calcul profund | `DirtyCpu` obligatoriu |
| `analyze_shadow` | analiză fără dezvăluire | **nu poate atinge plaintext** |
| `discern` | detecție de anomalie | doar metadate |
| `seal` / `unseal` | AEAD | operează pe mânere |
| `reveal` | materializare de plaintext | **singura ieșire; auditată** |
| `forget` | ștergere imediată | zeroizare, nu așteaptă GC |

### Registrul Nouălui — global, restaurativ (9)

| Cuvânt | Sens |
|---|---|
| `uplift_global` | acțiunea reparatoare a supervizorului |
| `absolve` | stingerea contoarelor de eroare în timp |
| `bequeath` | transmiterea stării salvabile către succesor |

---

## 5. Invariantul central — Pragmatism Idealist

```
command  : legal DOAR pe muchii de supervizare (vertical, descendent)
offer    : legal DOAR între egali (orizontal)
```

Nicio ființă nu poate comanda un frate. Niciun supervizor nu poate cere unui
copil să calculeze ceva. Exteriorul e autoritar; interiorul e egalitar; iar
granița dintre ele e verificabilă sintactic.

### Corecție #3 — `analyze_shadow` nu poate primi plaintext

Profilul sugerează că AI-ul „citește tiparele invizibile ale datelor". În
arhitectura zero-knowledge, asta e interzis: modelul vede exclusiv metadate —
dimensiuni, rate, latențe cuantizate, coduri de eșec.

Nu e o limitare a ambiției, e condiția ca modelul să nu devină un oracol. Un
model care ramifică pe date secrete *este* un canal lateral, indiferent cât de
bine intenționat e. Tiparele rămân vizibile; conținutul nu.
