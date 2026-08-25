%%%-------------------------------------------------------------------
%%% @doc Cercul: implinire, integritate, perspectiva globala.
%%%
%%% Aici blocam invariantele filozofice din Faza 1 -- cele care se strica
%%% TACUT. O cifrare rupta da un test rosu imediat; un supervizor care a
%%% inceput sa reporneasca fiinte implinite arata perfect normal si merge
%%% asa luni de zile.
%%%
%%% Fiecare caz primeste o adunare proaspata, ca sa nu imparta bugetul de
%%% `intensity' cu vecinii lui.
%%% @end
%%%-------------------------------------------------------------------
-module(bahmet_circle_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([completion_merges/1, broken_withholds/1,
         completion_is_not_failure/1, failure_is_not_completion/1,
         all_complete_dissolves_council/1, silence_releases/1,
         crash_report_redacts_insight/1,
         council_fall_spares_foundation/1, ground_fall_refounds_all/1]).

all() ->
    [completion_merges, broken_withholds,
     completion_is_not_failure, failure_is_not_completion,
     all_complete_dissolves_council, silence_releases,
     crash_report_redacts_insight,
     council_fall_spares_foundation,
     %% Ultimul: consuma cel mai mult din bugetul de iertare al radacinii.
     ground_fall_refounds_all].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(bahmet),
    Config.

end_per_suite(_Config) ->
    _ = application:stop(bahmet),
    ok.

init_per_testcase(_Case, Config) ->
    ensure_council(),
    Config.

%% Testele distructive lasa radacina intr-o stare consumata; le dam un sistem
%% nou. Celelalte primesc doar o adunare goala.
end_per_testcase(Case, _Config) when Case =:= ground_fall_refounds_all;
                                     Case =:= council_fall_spares_foundation ->
    _ = application:stop(bahmet),
    {ok, _} = application:ensure_all_started(bahmet),
    ok;
end_per_testcase(_Case, _Config) ->
    _ = supervisor:terminate_child(bahmet_sup, bahmet_council_sup),
    ok.

%%====================================================================
%% Daruire si integritate
%%====================================================================

%% Implinirea dăruieste.
completion_merges(_Config) ->
    Before = length(bahmet_commons:contributors()),
    {ok, Pid} = bahmet_council_sup:birth(<<"ce inseamna a completa">>),
    bahmet_contemplator:offer(Pid, seed()),
    ok = wait_settled(Pid),
    bahmet_contemplator:call_home(Pid),
    ok = wait_gone(Pid),
    timer:sleep(150),
    ?assertEqual(Before + 1, length(bahmet_commons:contributors())),
    ?assertMatch({ok, _}, bahmet_commons:wisdom()).

%% Ruptura NU daruieste -- clauza cea mai importanta din contemplator.
%%
%% Fiinta ARE o intelegere completa in stare cand moare. O stare pe jumatate
%% scrisa, varsata in bunul comun, ar otravi tacut fiecare intuitie viitoare
%% a fiecarei fiinte. A da nimic e, aici, actul cel mai altruist disponibil.
broken_withholds(_Config) ->
    Before = length(bahmet_commons:contributors()),
    {ok, Pid} = bahmet_council_sup:birth(<<"proba">>),
    bahmet_contemplator:offer(Pid, seed()),
    ok = wait_settled(Pid),
    exit(Pid, ruptura),
    ok = wait_gone(Pid),
    timer:sleep(150),
    ?assertEqual(Before, length(bahmet_commons:contributors())).

%%====================================================================
%% `transient': implinirea nu e esec
%%====================================================================

completion_is_not_failure(_Config) ->
    {ok, A} = bahmet_council_sup:birth(<<"a">>),
    {ok, B} = bahmet_council_sup:birth(<<"b">>),
    bahmet_contemplator:call_home(A),
    ok = wait_gone(A),
    timer:sleep(150),
    Present = bahmet_council_sup:present(),
    %% Terminarea normala nu se reporneste: supervizorul respecta ce s-a
    %% terminat, in loc sa reinvie la nesfarsit.
    ?assertNot(lists:member(A, Present)),
    ?assert(lists:member(B, Present)),
    ?assertEqual(1, length(Present)).

failure_is_not_completion(_Config) ->
    {ok, A} = bahmet_council_sup:birth(<<"a">>),
    {ok, _B} = bahmet_council_sup:birth(<<"b">>),
    exit(A, ruptura),
    ok = wait_gone(A),
    timer:sleep(300),
    Present = bahmet_council_sup:present(),
    %% Aceeasi cheie `transient', comportament opus: caderea se reporneste.
    ?assertNot(lists:member(A, Present)),
    ?assertEqual(2, length(Present)).

%% Intregul isi recunoaste propria implinire PRIN implinirea partilor.
%% Niciun cod nu numara, nu sondeaza, nu semnaleaza -- doar structura.
all_complete_dissolves_council(_Config) ->
    {ok, A} = bahmet_council_sup:birth(<<"a">>),
    {ok, B} = bahmet_council_sup:birth(<<"b">>),
    Council = whereis(bahmet_council_sup),
    Ref = monitor(process, Council),
    bahmet_contemplator:call_home(A),
    bahmet_contemplator:call_home(B),
    receive
        {'DOWN', Ref, process, Council, Reason} ->
            ?assert(lists:member(Reason, [shutdown, normal]))
    after 5000 -> ct:fail(adunarea_nu_s_a_stins)
    end,
    %% Bunul comun supravietuieste adunarii care l-a hranit.
    ?assert(is_pid(whereis(bahmet_commons))),
    ?assert(is_pid(whereis(bahmet_ground))).

%% Rabdarea are termen. Coborata la 300ms pentru proba.
silence_releases(_Config) ->
    ok = application:set_env(bahmet, patience, 300),
    try
        {ok, Pid} = bahmet_council_sup:birth(<<"tacere">>),
        Ref = monitor(process, Pid),
        receive
            {'DOWN', Ref, process, Pid, Reason} ->
                %% `{shutdown, _}' -- retragere, nu alarma. Pentru un copil
                %% `transient' asta nu declanseaza repornire: fiinta se
                %% retrage SI ramane catalogata drept implinita.
                ?assertEqual({shutdown, silence}, Reason)
        after 5000 -> ct:fail(rabdarea_nu_a_expirat)
        end
    after
        ok = application:set_env(bahmet, patience, 30000)
    end.

%% A doua iesire a starii.
%%
%% `terminate(_Broken, _)' refuza sa daruiasca -- dar error loggerul OTP
%% tipareste `#state{}' integral la prabusire, adica exact tensorul pe care
%% l-am refuzat. Integritatea care acopera o singura iesire nu e integritate.
crash_report_redacts_insight(_Config) ->
    {ok, Pid} = bahmet_council_sup:birth(<<"q">>),
    bahmet_contemplator:offer(Pid, seed()),
    ok = wait_settled(Pid),
    {status, _Pid, _Mod, Items} = sys:get_status(Pid),
    Formatted = lists:flatten(io_lib:format("~p", [Items])),
    %% Fiinta ARE o intelegere...
    ?assertMatch(#{settled := true}, bahmet_contemplator:reflection(Pid)),
    %% ...dar jurnalul nu o vede.
    ?assertNotEqual(nomatch, string:find(Formatted, "redacted")).

%%====================================================================
%% Perspectiva globala: `rest_for_one'
%%====================================================================

%% Nimic DINAINTEA adunarii nu e atins de caderea ei. Un `one_for_all' ar fi
%% sters intelepciunea castigata de generatiile anterioare -- perspectiva
%% globala panicata, nu superioara.
council_fall_spares_foundation(_Config) ->
    GroundBefore = whereis(bahmet_ground),
    CommonsBefore = whereis(bahmet_commons),
    exit(whereis(bahmet_council_sup), kill),
    timer:sleep(600),
    ?assertEqual(GroundBefore, whereis(bahmet_ground)),
    ?assertEqual(CommonsBefore, whereis(bahmet_commons)).

%% Temelia s-a schimbat: tot ce s-a ridicat DUPA ea se refondeaza.
%%
%% Contemplatorii tin un `ground()' devenit orfan si nu au cum sa afle
%% singuri. Doar supervizorul, care vede intregul, poate lua aceasta decizie.
%% Vederea locala nu ar fi produs-o niciodata.
ground_fall_refounds_all(_Config) ->
    {ok, _} = bahmet_council_sup:birth(<<"q">>),
    CouncilBefore = whereis(bahmet_council_sup),
    CommonsBefore = whereis(bahmet_commons),
    exit(whereis(bahmet_ground), kill),
    timer:sleep(900),
    ?assertNotEqual(CouncilBefore, whereis(bahmet_council_sup)),
    ?assertNotEqual(CommonsBefore, whereis(bahmet_commons)),
    ?assert(is_pid(whereis(bahmet_ground))),
    ?assertEqual([], bahmet_council_sup:present()).

%%====================================================================
%% Ajutoare
%%====================================================================

seed() ->
    Dimension = bahmet_ground:dimension(),
    lists:duplicate(Dimension, 1.0 / Dimension).

ensure_council() ->
    case whereis(bahmet_council_sup) of
        undefined ->
            _ = supervisor:restart_child(bahmet_sup, bahmet_council_sup),
            ok;
        Pid when is_pid(Pid) ->
            ok
    end.

%% Asteptam o conditie, nu un numar magic de milisecunde. `timer:sleep' fix
%% e cauza numarul unu a testelor care pica aleatoriu pe masini incarcate.
wait_settled(Pid) -> wait_settled(Pid, 50).
wait_settled(_Pid, 0) -> {error, timeout};
wait_settled(Pid, Tries) ->
    case catch bahmet_contemplator:reflection(Pid) of
        #{settled := true} -> ok;
        _ -> timer:sleep(20), wait_settled(Pid, Tries - 1)
    end.

wait_gone(Pid) ->
    Ref = monitor(process, Pid),
    receive
        {'DOWN', Ref, process, Pid, _} -> ok
    after 5000 ->
        demonitor(Ref, [flush]),
        {error, timeout}
    end.
