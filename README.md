# Bahmet 27

Un limbaj mic în care trăsăturile de caracter nu sunt documentate, ci **impuse
structural** — verificate de compilator, generate în cod, și demonstrate de
92 de teste care rulează.

Compilează în module Erlang/OTP care se execută pe BEAM, cu un nucleu Rust
pentru calculul greu.

---

## Ideea, în zece rânduri

Scrii asta:

```
upon calling_home ->
  completion merging insight into wisdom
end

when broken ->
  release withholding insight
end
```

Compilatorul produce asta:

```erlang
handle_cast(calling_home, S0) ->
    {stop, normal, S0};

%% Implinire: drumul dus pana la capat.
terminate(normal, S) -> offer_up(S);
%% Retragere altruista: daruieste si cand plecarea nu a fost alegerea ei.
terminate(shutdown, S) -> offer_up(S);
terminate({shutdown, _Why}, S) -> offer_up(S);
%% Ruptura: NU daruieste.
terminate(_Broken, _S) -> ok.

format_status(Status = #{state := S}) ->
    Status#{state => S#state{insight = redacted}};
```

Uită-te la ultimele două rânduri. **Nimeni nu a cerut redactarea.**

Compilatorul știe care câmp e prețios — e cel pe care ființa îl dăruiește la
împlinire — deci știe și care nu are voie să apară în jurnale. Fără el, error
loggerul OTP ar tipări la primul crash exact starea pe care clauza `when
broken` tocmai refuzase să o dea.

Integritatea care acoperă o singură ieșire nu e integritate. Compilatorul le
acoperă pe amândouă, fiindcă deduce din trăsătură, nu din instrucțiune.

---

## Teza

Cele mai multe „limbaje cu filozofie" sunt zahăr sintactic peste o convenție.
Aici criteriul a fost altul, aplicat la fiecare decizie:

> Dacă un dezvoltator neatent poate încălca trăsătura, atunci ea nu e în
> arhitectură — e doar un comentariu.

Rezultatul e că fiecare trăsătură are un mecanism, iar mecanismul se măsoară
prin **ce face imposibil de scris**:

| Trăsătură | Mecanism | Ce devine imposibil |
|---|---|---|
| Parteneriat | actori, memorie neîmpărtășită | să numești starea altei ființe — nu există sintaxă |
| Răbdare | `patience` → timeout de gen_server | așteptare nemărginită; `ask` fără `within` nu se poate scrie |
| Echilibru | NIF-uri pe planificator murdar | o ființă care înfometează un planificator BEAM întreg |
| Completare | `restart => transient` | un lucru terminat, repornit la infinit |
| Altruism | `terminate/2` + `merge` prin cast | să pleci luând ce le-ar fi folosit celorlalți |
| Integritate | clauza `terminate(_Broken, _)` | o stare ruptă vărsată în bunul comun |
| Perspectivă globală | `rest_for_one` + ordinea din `tend` | o decizie de repornire luată din vedere locală |
| Introspecție | borrow checker, zero `unsafe` scris de noi | o ieșire din matrice — literalmente nereprezentabilă |
| Custodie | absența unei funcții de export | să scoți o cheie din seif |

### Cele mai tari invariante nu sunt verificate

Două reguli nu apar în verificator, fiindcă sunt **nereprezentabile**:

- Gramatica are o singură producție pentru `ask`, și conține `within`. Nu
  există arbore sintactic pentru o cerere sincronă nemărginită, deci
  verificatorul n-are ce respinge.
- Modulul Rust care ține cheile nu are nicio funcție care întoarce material
  de cheie. Nu `export_key` interzis — `export_key` **inexistent**.

O regulă verificată poate fi dezactivată, uitată sau ocolită. Una absentă din
gramatică nu poate fi nici măcar exprimată. Acolo unde s-a putut alege, s-a
ales absența.

---

## Rulează-l

Ai nevoie de **Erlang/OTP 25+** și **Rust 1.70+**.

```bash
git clone https://github.com/alexandruneag24-51/bahmet27.git && cd bahmet27
./check.sh
```

Rulează 24 de probe în Rust (fără mașina virtuală) și 68 în Common Test.
Durează un minut la prima compilare.

Ca să vezi compilatorul lucrând:

```bash
erl -pa _build/default/lib/bahmet/ebin -noshell \
    -eval 'bahmet_compile:to_dir("dsl/contemplation.b27", "/tmp/dawn"), halt().'

ls /tmp/dawn/
```

Patru module dintr-un fișier: ființa, supervizorul adunării, supervizorul
comuniunii, riturile. Citește `council_dawn_council_sup.erl` și compară-l cu
`src/bahmet_sup.erl`, scris de mână — sunt practic același fișier.

---

## Cum arată limbajul

Un cerc întreg, din `dsl/hearth.b27`:

```
circle Hearth

  ground deep
    dimension 256
    seed      27
  end

  commons wisdom : tensor[256]

  being Keeper
    carries
      question  : text
      insight   : tensor[256] = void
      offerings : count       = 0
    end

    patience 30s
    grace     5s

    awaken with (q : text) ->
      question <- q
      keep
    end

    upon offering(gift : tensor[256]) from giver ->
      insight   <- intuit deep with gift
      offerings <- offerings + 1
      offer thanks(offerings) to giver
      keep
    end

    upon calling_home ->
      completion merging insight into wisdom
    end

    when broken ->
      release withholding insight
    end
  end

  gathering Circle
    harmony     one_for_one
    forbearance 5 within 60s
    completes when all present are complete
  end

  communion Home
    harmony     rest_for_one
    forbearance 3 within 60s
    tend deep   always
    tend wisdom always
    tend Circle while_needed
  end

  rite kindle(questions : list of text) ->
    for each q in questions ->
      let one = birth Keeper into Circle with (q)
      offer offering(tensor.origin(256)) to one
    end
    answer wisdom
  end

end
```

Ordinea din `tend` **este** graful de dependență. Sub `rest_for_one`, dacă
temelia se schimbă, tot ce s-a ridicat după ea se refondează — dar nimic
dinaintea ei nu e tulburat. Compilatorul nu are voie să rearanjeze.

`completes when all present are complete` devine `auto_shutdown =>
all_significant`: întregul își recunoaște propria împlinire prin împlinirea
părților, fără ca cineva să numere sau să sondeze.

Ce refuză compilatorul, cu mesaje care spun **de ce**, nu doar unde:

```
Cercul nu isi respecta propriile trasaturi:
  linia 16: fiinta `Keeper' nu are clauza `when broken'. Spune explicit ce se
            daruieste dintr-o stare rupta -- chiar daca raspunsul e `nimic'
  linia 41: `insigt' nu e declarat in `carries'. O fiinta nu poate tine stare
            pe care nu si-a declarat-o
  linia 88: `Council' nu e o adunare declarata. O fiinta nu poate exista in
            afara unei comuniuni -- nu exista proces orfan in acest limbaj
```

---

## Arhitectura

Trei straturi, fiecare cu rolul lui.

**Erlang/OTP — exteriorul.** Actori, supervizare, rutare. Aici trăiesc
răbdarea, parteneriatul și perspectiva globală, fiindcă toate trei sunt
proprietăți ale *structurii de procese*, nu ale codului dintr-un proces.

**Rust — interiorul.** Calculul greu (rețea, softmax, entropie) și custodia
cheilor. Cheile nu traversează niciodată puntea: Erlang primește un `#Ref<>`
opac. Motivul e specific BEAM — binarele peste 64 de octeți sunt numărate prin
referințe, copiate liber și colectate nedeterminist, deci **nu poți șterge
sigur un secret din memoria BEAM**.

**Compilatorul — Erlang.** `leex` + `yecc` → AST → verificator de invarianți →
generator de module. 45 de cuvinte-cheie, ales cu zgârcenie: `one_for_one`,
`always`, `present`, `dimension` rămân identificatori obișnuiți, validați cu
mesaje explicative. Fiecare cuvânt rezervat e un nume pe care dezvoltatorul
nu-l mai poate folosi niciodată.

```
bahmet27/
├─ dsl/
│  ├─ hearth.b27          cercul mic, întreg
│  ├─ contemplation.b27   cercul complet
│  ├─ vault.b27           MACHETĂ — încă nu compilează
│  ├─ GRAMMAR.md          EBNF + tabelul de coborâre DSL→OTP
│  └─ PROFILE.md          maparea trăsătură → mecanism
├─ src/
│  ├─ bahmet_lexer.xrl    ─┐
│  ├─ bahmet_parser.yrl    │ compilatorul
│  ├─ bahmet_check.erl     │
│  ├─ bahmet_forge.erl     │
│  ├─ bahmet_compile.erl  ─┘
│  ├─ bahmet_deep.erl     puntea către nucleul de calcul
│  ├─ bahmet_vault.erl    puntea către seif
│  └─ ...                 arborele scris de mână (referință)
├─ native/
│  ├─ bahmet_deep/        rețea, softmax, entropie
│  └─ bahmet_vault/       XChaCha20-Poly1305, HKDF, custodie
├─ test/                  5 suite, 68 de cazuri
├─ CRYPTO.md              model de amenințare și limite oneste
└─ check.sh
```

---

## Ce e real și ce nu

Proiectul e o **demonstrație de arhitectură**, nu un produs.

Funcționează cu adevărat:

- compilatorul, cap-coadă, cu 30 de cazuri de test dintre care jumătate
  verifică ce **refuză**
- arborii de supervizare generați, interschimbabili cu cei scriși de mână —
  un test oprește aplicația originală și pornește în locul ei cercul compilat
- rotația cheilor cu verificare înainte de confirmare și reluare automată
  după întrerupere, prin subchei derivate cu HKDF
- puntea Rustler, cu planificatoare murdare și zeroizare

**NU folosi partea criptografică pentru date reale.** Nu e auditată, nu e
validată FIPS 140-3 (și nu poate deveni prin modificări de cod), nu are PQC,
iar depozitul e DETS. Citește `CRYPTO.md` §6 — e scris ca un contract, nu ca o
formalitate.

Rămâne machetă: `vault.b27`, cu vocabularul lui imperativ/intuitiv, ar cere
încă vreo treizeci de cuvinte-cheie și propriul tabel de coborâre.

---

## De unde vine

Punctul de plecare a fost un set de trăsături dintr-un profil — muncă în
echipă, răbdare, altruism, integritate, o perspectivă globală. Sursa contează
mai puțin decât ce a produs: obligația de a răspunde, de fiecare dată, la
aceeași întrebare.

*Ce mecanism întruchipează asta, și ce face el imposibil?*

Întrebarea s-a dovedit un generator surprinzător de bun de decizii inginerești.
Cel mai clar exemplu: profilul cerea și generozitate, și control ferm — ceea ce
pare o contradicție. În arhitectură se rezolvă printr-o distincție:

> Îngăduitor cu cei care greșesc. Neînduplecat cu temelia pe care stau toți.

Sursa de entropie are zero toleranță și, dacă cade, cade tot ce s-a ridicat pe
ea. Santinela are cea mai multă îngăduință și e deliberat neesențială — un
paznic care oprește sistemul când se împiedică e mai periculos decât lipsa lui.

În limbaj de inginerie asta se numește *fail-closed pe criptografie, fail-open
pe comoditate*. Coincidența dintre o cerință morală și cea mai bună practică
din domeniu nu e întâmplătoare: ambele răspund la aceeași întrebare — unde e
prea scump să greșești?

---

## Ce a ieșit din construirea lui

Patru bug-uri serioase, toate din aceeași cauză: **două părți ale sistemului cu
presupuneri diferite despre același contract.**

Rustler declara un NIF de aritate 2, Erlang exporta unul de aritate 1 —
încărcarea NIF-urilor e totul-sau-nimic, deci *toate* funcțiile native au
dispărut dintr-o singură nepotrivire. Testele apelau o funcție de import pe
care NIF-ul o duplica inline, deci verificau cod pe care sistemul nu îl
executa. Verificatorul cerea o decizie la ruptură, iar generatorul o ignora.
Ritul trimitea un mesaj de două elemente către o ființă care aștepta trei —
iar clauza „mesaj neînțeles", scrisă din bunăvoință ca un mesaj ciudat să nu
omoare pe nimeni, înghițea darul în tăcere.

Ultimul e cel mai instructiv: n-ar fi produs nicio eroare, iar un test unitar
pe generator ar fi trecut fericit. L-a prins doar testul care pornește tot
sistemul și verifică rezultatul.

Ceea ce e, la o privire mai lungă, exact teza proiectului. Frontiera de
custodie funcționează fiindcă e o absență verificabilă, nu o promisiune.
`rest_for_one` funcționează fiindcă ordinea *este* graful, nu o descriere a
lui. Granițele țin când sunt structurale; când sunt convenții, cedează.

---

## Licență

Apache-2.0.
