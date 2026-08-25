# Bahmet 27 — Gramatică și coborâre (lowering)

Acest document este *contractul compilatorului*. Fiecare formă din limbaj are
o singură țintă de traducere. Dacă o formă nu are țintă, nu intră în limbaj.

---

## 1. Vocabular

| Cuvânt         | Rol                        | Ce refuză să existe                         |
|----------------|----------------------------|---------------------------------------------|
| `circle`       | unitate de compilare       | —                                            |
| `ground`       | poarta către Adânc (Rust)  | acces la Rust în afara unei temelii numite  |
| `commons`      | destinatarul împlinirilor  | memorie partajată scriabilă                  |
| `being`        | actor                      | obiect cu metode apelabile din exterior      |
| `carries`      | stare privată              | stare vizibilă altcuiva                      |
| `patience`     | limită de așteptare        | așteptare nemărginită                        |
| `grace`        | răgaz la plecare           | terminare brutală (`brutal_kill`)            |
| `awaken`       | inițializare               | constructor care poate eșua tăcut            |
| `keep`         | rămâi viu                  | buclă explicită                              |
| `upon`         | primire asincronă          | apel direct între ființe                     |
| `offer`        | dar asincron               | `send` fără destinatar declarat              |
| `ask … within` | cerere sincronă cu limită  | cerere sincronă fără limită                  |
| `answer`       | răspuns                    | —                                            |
| `intuit`       | traversarea punții         | apel FFI necontrolat                         |
| `reflect`      | introspecție               | citirea stării altcuiva                      |
| `completion`   | sfârșit împlinit + dăruire | „succes” care se repornește la nesfârșit     |
| `release`      | retragere altruistă        | scurgere de resurse                          |
| `birth`        | naștere sub supraveghere   | proces neorfan, dar nesupravegheat           |
| `communion`    | arbore de supervizare      | supervizare implicită                        |
| `harmony`      | strategie                  | strategie nedeclarată                        |
| `forbearance`  | intensity / period         | reîncercare infinită                         |
| `gathering`    | supervizor dinamic         | `spawn` liber                                |

**Regulă de proiectare:** coloana a treia e cea importantă. Un limbaj filozofic
nu e definit de ce permite, ci de ce face *imposibil de scris*.

---

## 2. EBNF (schiță, Faza 1)

```ebnf
circle        = "circle" qname , { decl } , "end" ;
decl          = ground | commons | being | communion | gathering | rite ;

ground        = "ground" ident , "dimension" int , "seed" int , "end" ;
commons       = "commons" ident ":" type ;

being         = "being" ident , carries , { attr } , { clause } , "end" ;
carries       = "carries" , { ident ":" type [ "=" literal ] } , "end" ;
attr          = ( "patience" | "grace" ) duration ;

clause        = awaken | upon | askc | broken ;
awaken        = "awaken" "with" params "->" body "end" ;
upon          = "upon" pattern [ "from" ident ] "->" body "end" ;
askc          = "ask" ident "within" duration "->" body "end" ;
broken        = "when" "broken" "->" body "end" ;

body          = { stmt } , terminator ;
stmt          = bind | offer | forloop | letb ;
bind          = ident "<-" expr ;
offer         = "offer" call "to" expr ;
letb          = "let" ident "=" expr ;
forloop       = "for" "each" ident "in" expr "->" { stmt } "end" ;

terminator    = "keep"
              | "answer" expr
              | "completion" "merging" expr "into" ident
              | "release" ( "quietly" [ "giving" expr ] | "withholding" expr ) ;

expr          = intuition | reflection | birthe | call | ident | literal ;
intuition     = "intuit" ident "with" expr ;
reflection    = "reflect" ident ;
birthe        = "birth" ident "into" ident "with" args ;

communion     = "communion" ident , "harmony" strategy ,
                "forbearance" int "within" duration , { tend } , "end" ;
tend          = "tend" ident ( "always" | "while_needed" | "once" ) ;
gathering     = "gathering" ident , "harmony" strategy ,
                "forbearance" int "within" duration ,
                [ "completes" "when" completion_rule ] , "end" ;
strategy      = "one_for_one" | "rest_for_one" | "one_for_all" ;

rite          = "rite" ident params [ "->" type ] "->" body "end" ;
type          = "text" | "count" | "tensor" "[" int "]" | "list" "of" type ;
duration      = int ( "ms" | "s" | "m" ) ;
```

---

## 3. Tabelul de coborâre

| DSL | Ținta OTP / Rust |
|---|---|
| `circle X` | aplicație OTP + prefix de modul |
| `ground g dimension D seed S` | `bahmet_ground` → `bahmet_deep:open_ground(D, S)` |
| `commons w : tensor[N]` | `bahmet_commons` (gen_server) |
| `being B` | modul `-behaviour(gen_server)` |
| `carries {...}` | `-record(state, {...})` |
| `patience T` | `T` în `{noreply, S, T}` / `{ok, S, T}` |
| `grace T` | `shutdown => T` în child spec |
| `awaken with (a) -> … keep` | `init([A]) -> {ok, S, Patience}` |
| `upon m(a) from g -> … keep` | `handle_cast({m, A}, S)` → `{noreply, S', Patience}` |
| `ask r within T -> answer E` | `handle_call(r, _From, S)` → `{reply, E, S, Patience}` |
| `offer m(a) to P` | `gen_server:cast(P, {m, A})` |
| `intuit g with X` | `bahmet_deep:intuit(Ground, X)` — NIF DirtyCpu |
| `reflect g` | `bahmet_deep:reflect(Ground)` — NIF normal |
| `completion merging I into w` | `{stop, normal, S}` + `terminate(normal, …)` care face merge |
| `release quietly giving I` | `{stop, {shutdown, silence}, S}` + merge în terminate |
| `release withholding I` | `terminate(_Abnormal, _)` → **fără** merge |
| `when broken` | clauza de fallback din `terminate/2` |
| `birth B into G with (a)` | `supervisor:start_child(G, ChildSpec)` |
| `communion` | modul `-behaviour(supervisor)` |
| `harmony S` | `strategy => S` |
| `forbearance N within T` | `intensity => N, period => T` |
| `tend x always` | `restart => permanent` |
| `tend x while_needed` | `restart => transient` |
| `tend x once` | `restart => temporary` |
| `completes when all present are complete` | `auto_shutdown => all_significant` + `significant => true` (OTP 24+) |

---

## 4. Invarianți impuși de compilator (Faza 2)

1. **Nicio ființă fără comuniune.** `birth` în afara unui `gathering` = eroare de
   compilare. Nu există procese orfane.
2. **Nicio cerere sincronă fără `within`.** Verificat sintactic.
3. **Niciun `intuit` în afara unui `ground` deschis.** Verificat prin scoping.
4. **`completion` implică un `commons` țintă.** Nu poți muri „împlinit" fără să dai.
5. **`carries` nu e adresabil din altă ființă.** Nu există sintaxă pentru asta.
6. **Fiecare `being` are o clauză `when broken`.** Compilatorul o cere explicit,
   ca autorul să decidă conștient ce se dăruiește dintr-o stare ruptă.
