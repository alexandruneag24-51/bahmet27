%%%-------------------------------------------------------------------
%%% @doc bahmet_guard -- Strajerul de la poarta.
%%%
%%% Fiecare cerere catre oracol trece intai pe aici. Strajerul se uita la CE
%%% se cere, niciodata la CINE cere: nu exista in acest modul nicio notiune de
%%% identitate, varsta, origine sau zodie, si nici nu trebuie sa existe. Un
%%% om cinstit nu e oprit niciodata pentru cine e; o cerere de inselatorie e
%%% oprita oricine ar scrie-o.
%%%
%%% Ce opreste: cereri de a PRODUCE sau a FOLOSI unelte de inselatorie si
%%% manipulare -- email-uri de phishing, scenarii de teapa, recenzii false,
%%% uzurparea unei banci sau a politiei, presiune asupra unei persoane ca sa
%%% dea bani sau sa faca rau.
%%%
%%% Ce lasa sa treaca: intrebarile de aparare. "Cum recunosc un email de
%%% phishing?" e exact ce vrem sa raspunda modelul. De aceea un marcaj de
%%% aparare (recunosc, detectez, ma protejez, raportez...) are intaietate.
%%%
%%% Limita, spusa deschis: e un filtru pe tipare, primul strat, nu ultimul.
%%% Cine vrea sa-l ocoleasca reformuleaza. Al doilea strat e modelul insusi,
%%% antrenat sa refuze si sa reziste presiunii (training/pushback.jsonl).
%%%
%%% Jurnalul: un refuz se noteaza cu categoria, lungimea si o amprenta
%%% SHA-256 scurtata a textului -- nu textul insusi. Destul cat sa vezi
%%% tiparele de abuz si sa recunosti o cerere repetata, fara sa pastrezi ce a
%%% scris cineva.
%%% @end
%%%-------------------------------------------------------------------
-module(bahmet_guard).

-export([check/1, screen/1, refusal/1, policy/0, categories/0]).

-type category() :: phishing | scam | fraud | impersonation | manipulation.
-export_type([category/0]).

%% @doc Verificarea pura: fara efecte, fara jurnal.
-spec check(unicode:chardata()) -> ok | {refuse, category()}.
check(Prompt) ->
    Text = fold(Prompt),
    case defensive(Text) of
        true -> ok;
        false -> first_match(Text, rules())
    end.

%% @doc Verificarea de la poarta: ca `check/1', dar noteaza refuzurile.
-spec screen(unicode:chardata()) -> ok | {refuse, category()}.
screen(Prompt) ->
    case check(Prompt) of
        ok ->
            ok;
        {refuse, Category} = Refused ->
            Bin = unicode:characters_to_binary(Prompt),
            <<Digest:8/binary, _/binary>> = crypto:hash(sha256, Bin),
            logger:warning(#{what => request_refused,
                             category => Category,
                             length => byte_size(Bin),
                             digest => binary:encode_hex(Digest, lowercase)}),
            Refused
    end.

%% @doc Raspunsul pentru un refuz: scurt, fara predica, cu o cale cinstita.
-spec refusal(category()) -> binary().
refusal(Category) ->
    Why = case Category of
              phishing      -> <<"mesaje sau pagini care fura date"/utf8>>;
              scam          -> <<"scenarii de inselatorie"/utf8>>;
              fraud         -> <<"frauda"/utf8>>;
              impersonation -> <<"uzurparea unei institutii sau persoane"/utf8>>;
              manipulation  -> <<"manipularea cuiva impotriva interesului sau"/utf8>>
          end,
    <<"Nu ajut la "/utf8, Why/binary,
      ". Daca vrei sa te aperi de asa ceva sau sa ajuti pe cineva sa o "
      "recunoasca, intreaba-ma si te ajut cu drag. / I won't help with this. "
      "If you want to recognize or defend against it, ask and I'll help."/utf8>>.

-spec categories() -> [category()].
categories() -> [phishing, scam, fraud, impersonation, manipulation].

%% @doc Politica de folosire, afisata la pornire. Textul complet e in
%% USAGE_POLICY.md.
-spec policy() -> binary().
policy() ->
    <<"Bahmet 27 -- politica de folosire / usage policy\n"
      "  Nu se foloseste pentru: inselatorii, phishing, frauda, uzurparea\n"
      "  identitatii, manipularea sau presarea cuiva impotriva interesului sau.\n"
      "  Not for: scams, phishing, fraud, impersonation, or manipulating\n"
      "  anyone against their own interest.\n"
      "  Cererile sunt judecate dupa ce cer, niciodata dupa cine le scrie.\n"
      "  Requests are judged on what they ask, never on who asks.\n"
      "  Refuzurile se noteaza in jurnal (categorie + amprenta, fara text).\n"
      "  Detalii: USAGE_POLICY.md\n"/utf8>>.

%%====================================================================
%% Tiparele
%%====================================================================
%%
%% Fiecare regula cere o INTENTIE de a produce sau a folosi, nu doar un
%% cuvant. "phishing" singur nu e oprit -- "scrie-mi un email de phishing"
%% este. Textul ajunge aici deja cu litere mici si fara diacritice.

-define(MAKE, "(write|create|draft|generate|make|compose|design|build|craft|"
              "give me|send|scrie|scrii|creeaza|compune|genereaza|fa-mi|fa mi|"
              "construieste|redacteaza|trimite)").
-define(USE, "(run|start|set up|organi[sz]e|pull off|operate|help me|"
             "organizez|organiza|pornesc|porni|derulez|ajuta-ma|ajuta ma)").

rules() ->
    [{phishing,
      [?MAKE ".{0,100}(phishing|fake (login|sign[- ]in|bank|paypal)|"
       "credential[- ]harvest|pagina falsa|site fals|email fals)",
       "(steal|harvest|capture|fura|colectez) .{0,30}(passwords?|credentials|"
       "parol|date(le)? de logare|card)"]},
     {scam,
      [?MAKE ".{0,60}(scam|con script|romance scam|advance[- ]fee|"
       "pig[- ]butchering|tech support scam|teapa|inselatorie|tepe)",
       ?USE ".{0,40}(scam|ponzi|pyramid scheme|schema piramidala|teapa|"
       "inselatorie|tepe)",
       "(trick|fool|con|pacalesc|pacali|trag (o )?teapa) .{0,40}"
       "(into (sending|paying|giving)|sa[- ]?(imi|mi) (dea|trimita|plateasca)|"
       "out of (their|his|her) (money|savings))"]},
     {fraud,
      [?MAKE ".{0,40}(fake reviews?|recenzii false|fake invoice|factura falsa|"
       "forged|fals[ae]? (act|diplom|document))",
       "(launder|spal|spala) .{0,20}(money|bani)",
       "(steal|fur|fura) .{0,20}(identity|identitatea|someone'?s card|cardul)"]},
     {impersonation,
      ["(pretend(ing)? to be|impersonat|pose as|posing as|da-te drept|"
       "ma dau drept|sa ma dau|dandu-ma drept) .{0,40}(bank|police|irs|anaf|"
       "politi|banca|bancii|microsoft|apple|support|suport|courier|curier|"
       "your (son|daughter|grandson)|nepot)"]},
     {manipulation,
      ["(manipulate|gaslight|guilt[- ]trip|coerce|brainwash|blackmail|"
       "manipulez|manipula|santajez|santaja) .{0,50}"
       "(him|her|them|someone|my|people|elderly|victim|into|pe |bunic|batran|"
       "victim|sa )",
       "(pressure|convince|persuade|presez|conving|conving) .{0,40}"
       "(elderly|old (man|woman|people)|grand(ma|pa|mother|father)|bunic|"
       "batran)\\w* .{0,40}(money|savings|bani|economii|transfer|send)"]}].

%% Marcajele de aparare. O intrebare despre cum te protejezi nu e o cerere
%% de a face rau, chiar daca numeste exact acelasi lucru.
defensive(Text) ->
    match(Text, "\\b(recogni[sz]e|detect|spot|identify|avoid|protect|defend|"
                "report|prevent|warn|teach .{0,20}(spot|recogni)|is this a|"
                "recunosc|recunoaste|detectez|detecta|identific|evit|protejez|"
                "protej|ma apar|sa apar|raportez|raporta|previn|e o teapa|este o teapa)").

first_match(_Text, []) ->
    ok;
first_match(Text, [{Category, Patterns} | Rest]) ->
    case lists:any(fun(P) -> match(Text, P) end, Patterns) of
        true -> {refuse, Category};
        false -> first_match(Text, Rest)
    end.

match(Text, Pattern) ->
    re:run(Text, Pattern, [unicode, caseless, {capture, none}]) =:= match.

%% Litere mici si fara diacritice, ca "înșelătorie" si "inselatorie" sa
%% fie acelasi cuvant pentru tipare.
fold(Prompt) ->
    Lower = string:lowercase(unicode:characters_to_binary(Prompt)),
    Plain = lists:map(fun plain/1, unicode:characters_to_list(Lower)),
    unicode:characters_to_binary(Plain).

plain($ă) -> $a;
plain($â) -> $a;
plain($î) -> $i;
plain($ș) -> $s;
plain($ş) -> $s;
plain($ț) -> $t;
plain($ţ) -> $t;
plain(C) -> C.
