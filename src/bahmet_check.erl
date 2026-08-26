%%%-------------------------------------------------------------------
%%% @doc bahmet_check -- Invariantele devin erori de compilare.
%%%
%%% Pana acum, regulile din dsl/GRAMMAR.md §4 erau conventii pe care le-am
%%% respectat fiindca le tineam minte. De aici incolo, compilatorul refuza
%%% codul care le incalca.
%%%
%%% Diferenta nu e de rigoare, e de natura. O conventie e o intentie; un
%%% invariant impus e o proprietate. Prima se erodeaza la al treilea
%%% dezvoltator si a doua zi de vineri; a doua nu.
%%%
%%% ═══════════════════════════════════════════════════════════════════
%%%  CE REFUZA, SI DE CE
%%% ═══════════════════════════════════════════════════════════════════
%%%
%%% Fiecare regula raspunde la o singura intrebare: ce trasatura ar deveni
%%% o minciuna daca am lasa asta sa treaca?
%%%
%%%   fara `when broken'      -> integritatea devine optionala
%%%   fara `patience'         -> asteptarea devine nemarginita
%%%   `completion' fara commons -> implinirea nu daruieste nimanui
%%%   `intuit' fara ground    -> intuitia sta pe un pamant inexistent
%%%   bind in afara `carries' -> starea inceteaza sa fie inchisa
%%%
%%% Mesajele spun DE CE, nu doar CE. Un compilator care raspunde „eroare de
%%% sintaxa la linia 12" te lasa sa ghicesti; unul care spune ce trasatura
%%% ai rupt te invata limbajul in timp ce il scrii.
%%% @end
%%%-------------------------------------------------------------------
-module(bahmet_check).

-export([circle/1, format/1]).

-type error() :: {Line :: pos_integer(), Message :: string()}.
-export_type([error/0]).

-spec circle(tuple()) -> ok | {error, [error()]}.
circle({circle, _Line, _Name, Decls}) ->
    Grounds = [Name || {ground, _, Name, _} <- Decls],
    Commons = [Name || {commons, _, Name, _} <- Decls],
    Beings = [B || B = {being, _, _, _, _, _} <- Decls],

    Errors = lists:flatten([
        [ground_settings(G) || G = {ground, _, _, _} <- Decls],
        duplicate_beings(Beings),
        [being(B, Grounds, Commons) || B <- Beings]
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

ground_settings({ground, Line, Name, Settings}) ->
    Keys = [K || {K, _V, _L} <- Settings],
    Missing = [K || K <- [dimension, seed], not lists:member(K, Keys)],
    Unknown = [{L, io_lib:format("`~s' nu are inteles intr-un `ground'; "
                                "asteptam `dimension' si `seed'", [K])}
               || {K, _V, L} <- Settings, not lists:member(K, [dimension, seed])],
    Absent = [{Line, io_lib:format("temelia `~s' nu declara `~s'. O temelie "
                                   "fara forma si fara samanta nu poate fi "
                                   "reprodusa dupa o repornire", [Name, K])}
              || K <- Missing],
    NonPositive = [{L, io_lib:format("`~s' trebuie sa fie pozitiv", [K])}
                   || {K, V, L} <- Settings, is_integer(V), V =< 0,
                      lists:member(K, [dimension, seed])],
    Unknown ++ Absent ++ NonPositive.

duplicate_beings(Beings) ->
    Names = [{N, L} || {being, L, N, _, _, _} <- Beings],
    Seen = [N || {N, _} <- Names],
    [{L, io_lib:format("fiinta `~ts' e declarata de mai multe ori", [N])}
     || {N, L} <- Names, count(N, Seen) > 1].

%%====================================================================
%% Fiinta
%%====================================================================

being({being, Line, Name, Fields, Attrs, Clauses}, Grounds, Commons) ->
    FieldNames = [F || {field, _, F, _, _} <- Fields],
    lists:flatten([
        integrity(Line, Name, Clauses),
        patience(Line, Name, Attrs),
        duplicate_fields(Fields),
        duplicate_clauses(Clauses),
        [clause(C, FieldNames, Grounds, Commons) || C <- Clauses]
    ]).

%% REGULA 1. Fiecare fiinta declara ce face cand se rupe.
%%
%% Nu impunem un raspuns anume -- poate darui, poate retine. Impunem ca
%% autorul sa fi DECIS. O clauza lipsa nu inseamna „nu conteaza", inseamna
%% „nu m-am gandit", iar diferenta se vede abia la primul crash in productie.
integrity(Line, Name, Clauses) ->
    case [C || C = {broken, _, _} <- Clauses] of
        [] ->
            [{Line, io_lib:format("fiinta `~ts' nu are clauza `when broken'. "
                                  "Spune explicit ce se daruieste dintr-o stare "
                                  "rupta -- chiar daca raspunsul e `nimic'", [Name])}];
        _ ->
            []
    end.

%% REGULA 2. Rabdarea e marginita sau nu e rabdare.
patience(Line, Name, Attrs) ->
    case [A || A = {attr, _, patience, _} <- Attrs] of
        [] ->
            [{Line, io_lib:format("fiinta `~ts' nu declara `patience'. O fiinta "
                                  "care ar astepta la nesfarsit nu e rabdatoare, "
                                  "e blocata -- si ocupa un loc pe care altcineva "
                                  "l-ar folosi", [Name])}];
        _ ->
            []
    end.

duplicate_fields(Fields) ->
    Names = [{F, L} || {field, L, F, _, _} <- Fields],
    All = [F || {F, _} <- Names],
    [{L, io_lib:format("campul `~s' e declarat de mai multe ori", [F])}
     || {F, L} <- Names, count(F, All) > 1].

duplicate_clauses(Clauses) ->
    Messages = [{M, L} || {upon, L, M, _, _, _} <- Clauses],
    All = [M || {M, _} <- Messages],
    [{L, io_lib:format("mesajul `~s' are mai multe clauze `upon'. A doua nu "
                       "va fi atinsa niciodata", [M])}
     || {M, L} <- Messages, count(M, All) > 1].

%%====================================================================
%% Clauze
%%====================================================================

clause({awaken, _L, Params, Body}, Fields, Grounds, Commons) ->
    body(Body, Fields, bound(Params), Grounds, Commons);
clause({upon, _L, _Msg, Params, Giver, Body}, Fields, Grounds, Commons) ->
    Visible = bound(Params) ++ [Giver || Giver =/= undefined],
    body(Body, Fields, Visible, Grounds, Commons);
clause({broken, _L, Body}, Fields, Grounds, Commons) ->
    body(Body, Fields, [], Grounds, Commons).

bound(Params) -> [N || {param, _, N, _} <- Params].

body({body, Stmts, Terminator}, Fields, Visible, Grounds, Commons) ->
    [[stmt(S, Fields, Visible, Grounds) || S <- Stmts],
     terminator(Terminator, Fields, Visible, Grounds, Commons)].

%% REGULA 3. Nu poti lega decat ce ai declarat in `carries'.
%%
%% Aceasta e forma verificabila a regulii „starea unei fiinte e inchisa".
%% Fara ea, `insigt <- ...' (cu typo) ar crea tacut un camp fantoma pe care
%% nimeni nu-l citeste vreodata.
stmt({bind, Line, Target, Expr}, Fields, Visible, Grounds) ->
    Unknown = case lists:member(Target, Fields) of
                  true -> [];
                  false ->
                      [{Line, io_lib:format("`~s' nu e declarat in `carries'. O "
                                            "fiinta nu poate tine stare pe care "
                                            "nu si-a declarat-o", [Target])}]
              end,
    Unknown ++ expr(Expr, Fields, Visible, Grounds);
stmt({offer, _Line, Call, Target}, Fields, Visible, Grounds) ->
    expr(Call, Fields, Visible, Grounds) ++ expr(Target, Fields, Visible, Grounds).

%% REGULA 4. `completion' cere un `commons' care exista.
%%
%% Implinirea inseamna a darui. Un `into' care nu numeste pe nimeni real e o
%% implinire care nu ajunge nicaieri.
terminator({completion, Line, Expr, Target}, Fields, Visible, Grounds, Commons) ->
    Missing = case lists:member(Target, Commons) of
                  true -> [];
                  false ->
                      [{Line, io_lib:format("`~s' nu e un `commons' declarat in "
                                            "acest cerc. Implinirea inseamna a "
                                            "darui cuiva anume", [Target])}]
              end,
    Missing ++ expr(Expr, Fields, Visible, Grounds);
terminator({release, _Line, _How, undefined}, _Fields, _Visible, _Grounds, _Commons) ->
    [];
terminator({release, _Line, _How, Expr}, Fields, Visible, Grounds, _Commons) ->
    expr(Expr, Fields, Visible, Grounds);
terminator({keep, _Line}, _Fields, _Visible, _Grounds, _Commons) ->
    [].

%%====================================================================
%% Expresii
%%====================================================================

%% REGULA 5. `intuit' cere o temelie declarata.
expr({intuit, Line, Ground, Inner}, Fields, Visible, Grounds) ->
    Missing = case lists:member(Ground, Grounds) of
                  true -> [];
                  false ->
                      [{Line, io_lib:format("temelia `~s' nu e declarata. O "
                                            "intuitie construita pe un pamant "
                                            "inexistent e mai rea decat nicio "
                                            "intuitie", [Ground])}]
              end,
    Missing ++ expr(Inner, Fields, Visible, Grounds);
expr({add, _Line, Left, Right}, Fields, Visible, Grounds) ->
    expr(Left, Fields, Visible, Grounds) ++ expr(Right, Fields, Visible, Grounds);
expr({call, _Line, _Name, Args}, Fields, Visible, Grounds) ->
    lists:flatten([expr(A, Fields, Visible, Grounds) || A <- Args]);
expr({var, Line, Name}, Fields, Visible, _Grounds) ->
    case lists:member(Name, Fields) orelse lists:member(Name, Visible) of
        true -> [];
        false ->
            [{Line, io_lib:format("`~s' nu e nici camp din `carries', nici "
                                  "parametru primit. Nu exista alta cale prin "
                                  "care o valoare sa ajunga aici", [Name])}]
    end;
expr({lit, _Line, _Value}, _Fields, _Visible, _Grounds) ->
    [].

%%====================================================================

count(X, List) -> length([Y || Y <- List, Y =:= X]).
