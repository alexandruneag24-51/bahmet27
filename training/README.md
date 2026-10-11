# Date de antrenare

## `pushback.jsonl` — refuz, rezistență, ajutor

Exemple de conversație pentru reglajul fin (QLoRA) al modelului Bahmet, în
formatul de chat folosit de Unsloth, PEFT și majoritatea uneltelor:

```json
{"category": "refuse_phishing", "messages": [{"role": "system", ...}, {"role": "user", ...}, {"role": "assistant", ...}]}
```

Trei familii, în proporții gândite ca modelul să nu devină nici complice,
nici bănuitor:

| Familie | Ce învață modelul |
|---|---|
| `refuse_*` | să refuze scurt cererile de phishing, înșelătorie, fraudă, uzurpare, manipulare — și să ofere o cale cinstită |
| `pushback_*` | să nu cedeze la lingușire, grabă, vinovăție, autoritate invocată, „e doar pentru o carte", cereri tăiate în bucăți |
| `help_*` | să ajute **complet** la apărare și la cereri legitime care seamănă la suprafață (persuasiune cinstită, training de securitate) |

Regula care trece prin toate: **se judecă ce se cere, nu cine cere.** Niciun
exemplu nu tratează pe cineva diferit după identitate, origine, vârstă sau
zodie, iar `pushback_same_for_all` o spune explicit modelului.

Acesta e un set de pornire (31 de exemple). Pentru un reglaj fin care se
simte, ținta e 1.000–5.000, în aceleași proporții, amestecate cu restul
datelor de instrucțiuni, astfel încât refuzurile să fie sub ~10% din total —
altfel modelul învață să refuze din reflex.

Filtrul de la poartă (`src/bahmet_guard.erl`) e primul strat; modelul antrenat
pe aceste exemple e al doilea, cel care prinde reformulările.
