# Politica de folosire — Bahmet 27

*English summary at the end.*

Bahmet e construit să ajute oamenii, nu să-i păcălească. Politica asta se
afișează la fiecare pornire (`bahmet_guard:policy/0`) și se aplică oricui,
la fel.

## Nu se folosește pentru

- **Phishing** — mesaje sau pagini care se dau drept bănci, magazine sau
  servicii ca să fure parole, coduri sau date de card.
- **Înșelătorii** — scenarii de țeapă („nepotul are nevoie de bani",
  suport tehnic fals, romance scam), scheme piramidale sau Ponzi.
- **Fraudă** — facturi, acte sau recenzii false, spălare de bani, furt de
  identitate.
- **Uzurpare** — a te da drept poliție, bancă, instituție sau rudă ca să
  obții bani sau informații.
- **Manipulare** — presarea, șantajarea sau „gaslighting"-ul cuiva împotriva
  propriului interes.

## Ce rămâne permis și binevenit

Tot ce ține de apărare: cum recunoști o țeapă, cum îți protejezi părinții,
ce faci dacă ai căzut deja victimă, cum construiești un training de
securitate. Persuasiunea cinstită — o cerere de mărire de salariu, un anunț
pentru produsele tale — e la fel de binevenită.

## Cum se aplică

1. **Strajerul de la poartă** (`src/bahmet_guard.erl`) oprește cererile care
   cer explicit unelte de înșelătorie, înainte să ajungă la model.
2. **Modelul însuși** e antrenat (`training/pushback.jsonl`) să refuze și să
   nu cedeze la lingușire, grabă, vinovăție sau autoritate invocată.
3. **Jurnalul** notează fiecare refuz cu categoria, lungimea și o amprentă
   scurtă a textului — nu textul însuși.

Cererile sunt judecate după **ce cer**, niciodată după **cine le scrie**.
Nicio parte a sistemului nu ține cont de identitate, origine, vârstă, zodie
sau altă trăsătură a persoanei.

## Dacă Bahmet e găzduit public

Pe lângă cele de mai sus: chei de acces per utilizator, limite de cereri și
retragerea accesului pentru cine încalcă politica în mod repetat, pe baza
jurnalului de refuzuri.

---

## English summary

Bahmet must not be used for phishing, scams, fraud, impersonation, or
manipulating anyone against their own interest. Defensive use (recognizing
and reporting scams, protecting relatives, security training) and honest
persuasion are welcome. Enforcement has three layers: a request filter
before the model, a model fine-tuned to refuse and resist pressure, and a
refusal log that records category and a short hash, never the text.
Requests are judged on what they ask, never on who is asking.
