%%%-------------------------------------------------------------------
%%% @doc bahmet_check -- Invariantele devin erori de compilare.
%%%
%%% Regulile din dsl/GRAMMAR.md §4 nu mai sunt conventii tinute minte.
%%% Diferenta nu e de rigoare, e de natura: o conventie e o intentie, un
%%% invariant impus e o proprietate. Prima se erodeaza la al treilea
%%% dezvoltator si a doua zi de vineri; a doua nu.
%%%
%%% ═══════════════════════════════════════════════════════════════════
%%%  DOUA DINTRE REGULI NU SUNT AICI
%%% ═══════════════════════════════════════════════════════════════════
%%%
%%% §4.2 -- „nicio cerere sincrona fara `within'" -- nu se verifica, e
%%% NEREPREZENTABILA. Gramatica are o singura productie pentru `ask', si ea
%%% contine `within'. Nu exista arbore sintactic de respins.
%%%
%%% §4.5 -- „`carries' nu e adresabil din alta fiinta" -- la fel: nu exista
%%% sintaxa pentru a numi starea altcuiva.
%%%
%%% O regula verificata poate fi dezactivata, uitata sau ocolita. Una absenta
%%% din gramatica nu poate fi nici macar exprimata. Acolo unde am putut alege,
%%% am ales absenta.
%%%
%%% ═══════════════════════════════════════════════════════════════════
%%%  CE REFUZA VERIFICATORUL, SI DE CE
%%% ═══════════════════════════════════════════════════════════════════
%%%
%%% Fiecare regula raspunde la o intrebare: ce trasatura ar deveni o
%%% minciuna daca am lasa asta sa treaca?
%%%
%%%   fara `when broken'        -> integritatea devine optionala
%%%   fara `patience'           -> asteptarea devine nemarginita
%%%   `completion' fara commons -> implinirea nu daruieste nimanui
%%%   `intuit' fara ground      -> intuitia sta pe un pamant inexistent
%%%   bind in afara `carries'   -> starea inceteaza sa fie inchisa
%%%   fiinta neadunata          -> exista cod pentru cineva care nu se poate naste
%%%
%%% Mesajele spun DE CE, nu doar CE. Un compilator care raspunde „eroare la
%%% linia 12" te lasa sa ghicesti; unul care spune ce trasatura ai rupt te
%%% invata limbajul in timp ce il scrii.
%%% @end
%%%-------------------------------------------------------------------
-module(bahmet_check).

-export([circle/1, format/1, strategies/0, lifetimes/0, builtins/0]).

-type error() :: {Line :: pos_integer(), Message :: string()}.
-export_type([error/0]).

-record(world, {
    grounds = []    :: [atom()],
    commons = []    :: [atom()],
    beings = []     :: [binary()],
    gatherings = [] :: [binary()],
    communions = [] :: [binary()]
}).

-record(scope, {
    world        :: #world{},
    fields = []  :: [atom()],
    visible = [] :: [atom()],
    kind         :: being | ask | rite
}).

strategies() -> [one_for_one, rest_for_one, one_for_all].
lifetimes() -> [always, while_needed, once].
builtins() -> [{tensor, origin, 1}].

%%====================================================================

-spec circle(tuple()) -> ok | {error, [error()]}.
circle({circle, _Line, _Name, Decls}) ->
    World = #world{
        grounds = [N || {ground, _, N, _} <- Decls],
        commons = [N || {commons, _, N, _} <- Decls],
        beings = [N || {being, _, N, _, _, _} <- Decls],
        gatherings = [N || {gathering, _, N, _, _, _} <- Decls],
        communions = [N || {communion, _, N, _, _, _} <- Decls]
    },
    Errors = lists:flatten([
        [ground(G) || G = {ground, _, _, _} <- Decls],
        duplicates(Decls),
        [being(B, World) || B = {being, _, _, _, _, _} <- Decls],
        [communion(C, World) || C = {communion, _, _, _, _, _} <- Decls],
        [gathering(G) || G = {gathering, _, _, _, _, _} <- Decls],
        [rite(R, World) || R = {rite, _, _, _, _} <- Decls],
        unreachable_beings(Decls)
    ]),
    case lists:usort(Errors) of
        [] -> ok;
        Found -> {error, Found}
    end.

-spec format([error()]) -> string().
format(Errors) ->
    lists:flatten([io_lib:format("  linia ~p: ~ts~n", [L, M]) || {L, M} <- Errors]).

%%====================================================================
%% Temelia
%%====================================================================

ground({ground, Line, Name, Settings}) ->
    Keys = [K || {K, _, _} <- Settings],
    Unknown = [{L, io_lib:format("`~s' nu are inteles intr-un `ground'; "
                                 "asteptam `dimension' si `seed'", [K])}
               || {K, _, L} <- Settings, not lists:member(K, [dimension, seed])],
    Absent = [{Line, io_lib:format("temelia `~s' nu declara `~s'. O temelie fara "
                                   "forma si fara samanta nu poate fi reprodusa "
                                   "dupa o repornire", [Name, K])}
              || K <- [dimension, seed], not lists:member(K, Keys)],
    NonPositive = [{L, io_lib:format("`~s' trebuie sa fie pozitiv", [K])}
                   || {K, V, L} <- Settings, is_integer(V), V =< 0,
                      lists:member(K, [dimension, seed])],
    Unknown ++ Absent ++ NonPositive.

duplicates(Decls) ->
    Named = [{N, L, "fiinta"} || {being, L, N, _, _, _} <- Decls]
         ++ [{N, L, "adunarea"} || {gathering, L, N, _, _, _} <- Decls]
         ++ [{N, L, "comuniunea"} || {communion, L, N, _, _, _} <- Decls]
         ++ [{atom_to_binary(N, utf8), L, "ritul"} || {rite, L, N, _, _} <- Decls],
    All = [N || {N, _, _} <- Named],
    [{L, io_lib:format("~s `~ts' e declarat de mai multe ori", [What, N])}
     || {N, L, What} <- Named, count(N, All) > 1].

%%====================================================================
%% Fiinta
%%====================================================================

being({being, Line, Name, Fields, Attrs, Clauses}, World) ->
    FieldNames = [F || {field, _, F, _, _} <- Fields],
    Base = #scope{world = World, fields = FieldNames, kind = being},
    lists:flatten([
        integrity(Line, Name, Clauses),
        patience(Line, Name, Attrs),
        duplicate_fields(Fields),
        duplicate_clauses(Clauses),
        [clause(C, Base) || C <- Clauses]
    ]).

%% REGULA 1. Fiecare fiinta declara ce face cand se rupe.
%%
%% Nu impunem un raspuns anume -- poate darui, poate retine. Impunem ca
%% autorul sa fi DECIS. O clauza lipsa nu inseamna „nu conteaza", inseamna
%% „nu m-am gandit", iar diferenta se vede abia la primul crash in productie.
integrity(Line, Name, Clauses) ->
    case [C || C = {broken, _, _} <- Clauses] of
        [] -> [{Line, io_lib:format("fiinta `~ts' nu are clauza `when broken'. "
                                    "Spune explicit ce se daruieste dintr-o stare "
                                    "rupta -- chiar daca raspunsul e `nimic'", [Name])}];
        _ -> []
    end.

%% REGULA 2. Rabdarea e marginita sau nu e rabdare.
patience(Line, Name, Attrs) ->
    case [A || A = {attr, _, patience, _} <- Attrs] of
        [] -> [{Line, io_lib:format("fiinta `~ts' nu declara `patience'. O fiinta "
                                    "care ar astepta la nesfarsit nu e rabdatoare, "
                                    "e blocata -- si ocupa un loc pe care altcineva "
                                    "l-ar folosi", [Name])}];
        _ -> []
    end.

duplicate_fields(Fields) ->
    Named = [{F, L} || {field, L, F, _, _} <- Fields],
    All = [F || {F, _} <- Named],
    [{L, io_lib:format("campul `~s' e declarat de mai multe ori", [F])}
     || {F, L} <- Named, count(F, All) > 1].

duplicate_clauses(Clauses) ->
    Named = [{M, L} || {upon, L, M, _, _, _} <- Clauses]
         ++ [{M, L} || {ask, L, M, _, _} <- Clauses],
    All = [M || {M, _} <- Named],
    [{L, io_lib:format("mesajul `~s' are mai multe clauze. A doua nu va fi "
                       "atinsa niciodata", [M])}
     || {M, L} <- Named, count(M, All) > 1].

clause({awaken, _L, Params, Body}, Scope) ->
    body(Body, Scope#scope{visible = bound(Params)});
clause({upon, _L, _Msg, Params, Giver, Body}, Scope) ->
    Visible = bound(Params) ++ [G || G <- [Giver], G =/= undefined],
    body(Body, Scope#scope{visible = Visible});
clause({ask, _L, _Msg, _Within, Body}, Scope) ->
    body(Body, Scope#scope{kind = ask});
clause({broken, _L, Body}, Scope) ->
    body(Body, Scope).

bound(Params) -> [N || {param, _, N, _} <- Params].

%%====================================================================
%% Comuniunea si adunarea
%%====================================================================

communion({communion, _Line, Name, Harmony, Forbearance, Tends}, World) ->
    lists:flatten([
        harmony(Harmony, Name),
        forbearance(Forbearance, Name),
        [tend(T, World) || T <- Tends]
    ]).

gathering({gathering, _Line, Name, Harmony, Forbearance, Rule}) ->
    lists:flatten([
        harmony(Harmony, Name),
        forbearance(Forbearance, Name),
        completion_rule(Rule, Name)
    ]).

harmony({harmony, Line, Strategy}, Name) ->
    case lists:member(Strategy, strategies()) of
        true -> [];
        false ->
            [{Line, io_lib:format("`~s' nu e o strategie de supervizare. `~ts' "
                                  "poate fi ~s", [Strategy, Name, names(strategies())])}]
    end.

%% Ingaduinta e marginita sau nu e ingaduinta. Un supervizor care ar reporni
%% la infinit nu e rabdator, e orb -- ar arde un nucleu ascunzand problema
%% reala de sub ochii tuturor.
forbearance({forbearance, Line, Intensity, Period}, Name) ->
    [{Line, io_lib:format("`forbearance' negativ nu are inteles pentru `~ts'",
                          [Name])} || Intensity < 0]
    ++ [{Line, io_lib:format("fereastra de ingaduinta a lui `~ts' e zero. O "
                             "toleranta fara durata nu tolereaza nimic", [Name])}
        || Period =< 0].

completion_rule(undefined, _Name) -> [];
completion_rule({completes, _Line, [all, present, are, complete]}, _Name) -> [];
completion_rule({completes, Line, _Other}, Name) ->
    [{Line, io_lib:format("nu inteleg conditia de implinire a lui `~ts'. Singura "
                          "forma cunoscuta e `completes when all present are "
                          "complete'", [Name])}].

tend({tend, Line, {small, Target}, Lifetime}, World) ->
    Known = lists:member(Target, World#world.grounds)
        orelse lists:member(Target, World#world.commons),
    unknown_tend(Line, Target, Known) ++ lifetime(Line, Target, Lifetime);
tend({tend, Line, {great, Target}, Lifetime}, World) ->
    Problem =
        case {lists:member(Target, World#world.gatherings),
              lists:member(Target, World#world.beings)} of
            {true, _} -> [];
            {false, true} ->
                [{Line, io_lib:format("`~ts' e o fiinta, nu o adunare. Fiintele nu "
                                      "se tin direct -- se nasc intr-o adunare, "
                                      "care le da si argumentele cu care se "
                                      "trezesc", [Target])}];
            {false, false} -> unknown_tend(Line, Target, false)
        end,
    Problem ++ lifetime(Line, Target, Lifetime).

unknown_tend(_Line, _Target, true) -> [];
unknown_tend(Line, Target, false) ->
    [{Line, io_lib:format("`~ts' nu e declarat in acest cerc. O comuniune nu poate "
                          "tine ceva ce nu exista", [Target])}].

lifetime(Line, Target, Lifetime) ->
    case lists:member(Lifetime, lifetimes()) of
        true -> [];
        false ->
            [{Line, io_lib:format("`~s' nu e un fel de a tine pe `~ts'. Alege intre "
                                  "~s", [Lifetime, Target, names(lifetimes())])}]
    end.

%% GRAMMAR.md §4.1. Nicio fiinta fara comuniune.
%%
%% O fiinta pe care nimeni nu o tine si pe care niciun rit nu o naste e cod
%% pentru cineva care nu se poate intampla. Nu e o eroare de logica -- e o
%% intentie ramasa neterminata, iar compilatorul o spune acum, nu peste sase
%% luni cand cineva se intreaba de ce nu se executa nimic.
unreachable_beings(Decls) ->
    %% Singura cale de a veni la viata e `birth ... into <adunare>'. Nu exista
    %% alta -- comuniunea tine adunari, nu fiinte.
    Reachable = lists:flatten([births(Body) || {rite, _, _, _, Body} <- Decls]),
    [{L, io_lib:format("fiinta `~ts' nu e nici tinuta de o comuniune, nici nascuta "
                       "de vreun rit. Nimeni nu o poate aduce la viata", [N])}
     || {being, L, N, _, _, _} <- Decls, not lists:member(N, Reachable)].

births({body, Stmts, Terminator}) ->
    lists:flatten([[births_stmt(S) || S <- Stmts], births_expr(Terminator)]).

births_stmt({'let', _, _, Expr}) -> births_expr(Expr);
births_stmt({bind, _, _, Expr}) -> births_expr(Expr);
births_stmt({offer, _, Message, Target}) -> births_expr(Message) ++ births_expr(Target);
births_stmt({foreach, _, _, Over, Inner}) ->
    births_expr(Over) ++ lists:flatten([births_stmt(S) || S <- Inner]);
births_stmt(_) -> [].

births_expr({birth, _, Being, _Gathering, Args}) ->
    [Being | lists:flatten([births_expr(A) || A <- Args])];
births_expr({add, _, L, R}) -> births_expr(L) ++ births_expr(R);
births_expr({intuit, _, _, Inner}) -> births_expr(Inner);
births_expr({call, _, _, Args}) -> lists:flatten([births_expr(A) || A <- Args]);
births_expr({builtin, _, _, _, Args}) -> lists:flatten([births_expr(A) || A <- Args]);
births_expr({answer, _, Expr}) -> births_expr(Expr);
births_expr({completion, _, Expr, _}) -> births_expr(Expr);
births_expr({release, _, _, Expr}) when Expr =/= undefined -> births_expr(Expr);
births_expr(_) -> [].

%%====================================================================
%% Ritul
%%====================================================================

rite({rite, _Line, _Name, Params, Body}, World) ->
    body(Body, #scope{world = World, visible = bound(Params), kind = rite}).

%%====================================================================
%% Corpuri
%%====================================================================

body({body, Stmts, Terminator}, Scope) ->
    {Errors, Final} = lists:foldl(
        fun(Stmt, {Acc, S}) ->
            {E, Next} = stmt(Stmt, S),
            {[Acc, E], Next}
        end, {[], Scope}, Stmts),
    [Errors, terminator(Terminator, Final)].

%% REGULA 3. Nu poti lega decat ce ai declarat in `carries'.
%%
%% Forma verificabila a regulii „starea unei fiinte e inchisa". Fara ea,
%% `insigt <- ...' (cu typo) ar crea tacut un camp fantoma pe care nimeni
%% nu-l citeste vreodata.
stmt({bind, Line, Target, Expr}, Scope) ->
    Unknown = [{Line, io_lib:format("`~s' nu e declarat in `carries'. O fiinta nu "
                                    "poate tine stare pe care nu si-a declarat-o",
                                    [Target])}
               || not lists:member(Target, Scope#scope.fields)],
    {Unknown ++ expr(Expr, Scope), Scope};
stmt({offer, _Line, Message, Target}, Scope) ->
    {expr(Message, Scope) ++ expr(Target, Scope), Scope};
stmt({'let', _Line, Name, Expr}, Scope) ->
    {expr(Expr, Scope), Scope#scope{visible = [Name | Scope#scope.visible]}};
stmt({foreach, _Line, Name, Over, Inner}, Scope) ->
    Opened = Scope#scope{visible = [Name | Scope#scope.visible]},
    {Errors, _} = lists:foldl(
        fun(S, {Acc, Sc}) -> {E, Next} = stmt(S, Sc), {[Acc, E], Next} end,
        {[], Opened}, Inner),
    %% Variabila ciclului nu supravietuieste ciclului: intoarcem domeniul
    %% dinainte. Ce e legat inauntru ramane inauntru.
    {expr(Over, Scope) ++ lists:flatten(Errors), Scope};
stmt({await, Line, Gathering, _Within}, Scope) ->
    World = Scope#scope.world,
    Missing = [{Line, io_lib:format("`~ts' nu e o adunare declarata. Nu poti astepta "
                                    "implinirea a ceva ce nu se aduna", [Gathering])}
               || not lists:member(Gathering, World#world.gatherings)],
    {Missing, Scope}.

%% REGULA 4. Terminatorul trebuie sa aiba inteles in locul unde apare.
terminator({keep, Line}, #scope{kind = Kind}) when Kind =/= being ->
    [{Line, "`keep' are inteles doar intr-o clauza de fiinta -- un rit se "
            "termina, nu ramane"}];
terminator({keep, _Line}, _Scope) ->
    [];
terminator({answer, Line, Expr}, Scope = #scope{kind = being}) ->
    [{Line, "`answer' are inteles doar in `ask' sau intr-un rit. O clauza `upon' "
            "primeste un dar, nu o cerere"} | expr(Expr, Scope)];
terminator({answer, _Line, Expr}, Scope) ->
    expr(Expr, Scope);
terminator({completion, Line, Expr, Target}, Scope) ->
    World = Scope#scope.world,
    Context = [{Line, "`completion' apartine unei fiinte -- doar ea are ce darui"}
               || Scope#scope.kind =/= being],
    Missing = [{Line, io_lib:format("`~s' nu e un `commons' declarat in acest cerc. "
                                    "Implinirea inseamna a darui cuiva anume",
                                    [Target])}
               || not lists:member(Target, World#world.commons)],
    Context ++ Missing ++ expr(Expr, Scope);
terminator({release, Line, _How, Expr}, Scope) ->
    Context = [{Line, "`release' apartine unei fiinte"} || Scope#scope.kind =/= being],
    Context ++ case Expr of
                   undefined -> [];
                   _ -> expr(Expr, Scope)
               end.

%%====================================================================
%% Expresii
%%====================================================================

%% REGULA 5. `intuit' cere o temelie declarata.
expr({intuit, Line, Ground, Inner}, Scope) ->
    ground_ref(Line, Ground, Scope) ++ expr(Inner, Scope);
expr({reflect, Line, Ground}, Scope) ->
    ground_ref(Line, Ground, Scope);

%% REGULA 6 (GRAMMAR.md §4.1). Nasterea are loc intr-o adunare, mereu.
%%
%% Gramatica impune deja `into' -- nu exista `birth' fara destinatie. Aici
%% verificam doar ca destinatia exista si ca cel nascut e cunoscut.
expr({birth, Line, Being, Gathering, Args}, Scope) ->
    World = Scope#scope.world,
    [{Line, io_lib:format("`~ts' nu e o fiinta declarata in acest cerc", [Being])}
     || not lists:member(Being, World#world.beings)]
    ++ [{Line, io_lib:format("`~ts' nu e o adunare declarata. O fiinta nu poate "
                             "exista in afara unei comuniuni -- nu exista proces "
                             "orfan in acest limbaj", [Gathering])}
        || not lists:member(Gathering, World#world.gatherings)]
    ++ lists:flatten([expr(A, Scope) || A <- Args]);

expr({builtin, Line, Namespace, Name, Args}, Scope) ->
    [{Line, io_lib:format("`~s.~s/~p' nu e o functie cunoscuta",
                          [Namespace, Name, length(Args)])}
     || not lists:member({Namespace, Name, length(Args)}, builtins())]
    ++ lists:flatten([expr(A, Scope) || A <- Args]);

expr({reach, Line, Gathering, Field}, Scope) ->
    World = Scope#scope.world,
    [{Line, io_lib:format("`~ts' nu e o adunare declarata", [Gathering])}
     || not lists:member(Gathering, World#world.gatherings)]
    ++ [{Line, io_lib:format("o adunare nu are `~s'. Poti cere doar `present'",
                             [Field])} || Field =/= present];

expr({add, _Line, Left, Right}, Scope) ->
    expr(Left, Scope) ++ expr(Right, Scope);
expr({call, _Line, _Name, Args}, Scope) ->
    lists:flatten([expr(A, Scope) || A <- Args]);
expr({var, Line, Name}, Scope) ->
    World = Scope#scope.world,
    case lists:member(Name, Scope#scope.fields)
        orelse lists:member(Name, Scope#scope.visible)
        orelse lists:member(Name, World#world.commons) of
        true -> [];
        false ->
            [{Line, io_lib:format("`~s' nu e nici camp din `carries', nici parametru "
                                  "primit, nici `commons'. Nu exista alta cale prin "
                                  "care o valoare sa ajunga aici", [Name])}]
    end;
expr({lit, _Line, _Value}, _Scope) ->
    [].

ground_ref(Line, Ground, Scope) ->
    World = Scope#scope.world,
    [{Line, io_lib:format("temelia `~s' nu e declarata. O intuitie construita pe un "
                          "pamant inexistent e mai rea decat nicio intuitie", [Ground])}
     || not lists:member(Ground, World#world.grounds)].

%%====================================================================

names(Atoms) -> string:join([atom_to_list(A) || A <- Atoms], ", ").

count(X, List) -> length([Y || Y <- List, Y =:= X]).
