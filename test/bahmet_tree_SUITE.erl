%%%-------------------------------------------------------------------
%%% @doc Gradientul de iertare.
%%%
%%% Profilul cere generozitate (Calea Vietii 9) si control executiv ferm
%%% (Calul de Foc). Nu se impaca printr-un compromis, ci printr-o distinctie:
%%%
%%%     Ingaduitor cu cei care gresesc.
%%%     Neinduplecat cu temelia pe care stau toti.
%%%
%%% Generozitatea aplicata uniform nu e virtute, e incapacitatea de a
%%% distinge ce conteaza. Cazurile de aici masoara exact acea distinctie.
%%%
%%% Fiecare caz primeste un arbore proaspat: omoram procese, iar bugetul de
%%% `intensity' nu trebuie sa se scurga dintr-un test in urmatorul.
%%% @end
%%%-------------------------------------------------------------------
-module(bahmet_tree_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([trust_order_holds/1, sentinel_fall_spares_core/1,
         custody_fall_spares_entropy/1, entropy_fall_refounds_custody/1,
         keyring_refuses_without_root/1, keyring_redacts_root/1]).

all() ->
    [trust_order_holds, sentinel_fall_spares_core,
     custody_fall_spares_entropy, entropy_fall_refounds_custody,
     keyring_refuses_without_root, keyring_redacts_root].

init_per_suite(Config) ->
    %% Radacina injectata din exterior. In productie vine dintr-un HSM si nu
    %% atinge niciodata BEAM -- vezi CRYPTO.md. Aici e destul sa existe.
    true = os:putenv("BAHMET_ROOT_KEY", lists:duplicate(64, $a)),
    {ok, _} = application:ensure_all_started(bahmet),
    Config.

end_per_suite(_Config) ->
    _ = application:stop(bahmet),
    ok.

%% Acest caz trebuie sa porneasca singur un keyring, deci NU vrea un arbore
%% deja pornit care sa fi ocupat numele.
init_per_testcase(keyring_refuses_without_root, Config) ->
    Config;
init_per_testcase(_Case, Config) ->
    {ok, Sup} = bahmet_vault_sup:start_link(),
    %% Dezlegam: prabusirile din proba nu au voie sa ucida procesul de test.
    unlink(Sup),
    [{sup, Sup} | Config].

end_per_testcase(_Case, Config) ->
    case proplists:get_value(sup, Config) of
        undefined -> ok;
        Sup -> stop_sync(Sup)
    end.

%%====================================================================

trust_order_holds(_Config) ->
    Names = [bahmet_entropy, bahmet_keyring, bahmet_rotation, bahmet_sentinel],
    Pids = [whereis(N) || N <- Names],
    ?assertEqual([], [N || {N, undefined} <- lists:zip(Names, Pids)]),
    ?assertEqual({ok, true}, bahmet_vault:entropy_health()).

%% Santinela e cea mai iertata, si deliberat neesentiala.
%%
%% Un observator care poate opri sistemul cand se impiedica e mai periculos
%% decat lipsa observatorului: devine un vector de indisponibilitate pe care
%% un atacator il declanseaza intentionat. Daca pica, seiful merge orb, dar viu.
sentinel_fall_spares_core(_Config) ->
    Core = [whereis(N) || N <- [bahmet_entropy, bahmet_keyring, bahmet_rotation]],
    exit(whereis(bahmet_sentinel), kill),
    timer:sleep(500),
    ?assertEqual(Core,
                 [whereis(N) || N <- [bahmet_entropy, bahmet_keyring, bahmet_rotation]]).

%% `rest_for_one': nimic DINAINTEA custodiei nu e atins de caderea ei.
custody_fall_spares_entropy(_Config) ->
    EntropyBefore = whereis(bahmet_entropy),
    exit(whereis(bahmet_keyring), kill),
    timer:sleep(600),
    ?assertEqual(EntropyBefore, whereis(bahmet_entropy)),
    ?assert(is_pid(whereis(bahmet_keyring))).

%% ...si opusul: temelia cade, tot ce s-a ridicat pe ea se refondeaza.
%%
%% Cheile faurite dupa o sursa suspecta sunt suspecte, iar cei care le tin nu
%% au cum sa afle singuri. Supervizorul decide pentru ei.
entropy_fall_refounds_custody(_Config) ->
    KeyringBefore = whereis(bahmet_keyring),
    exit(whereis(bahmet_entropy), kill),
    timer:sleep(900),
    KeyringAfter = whereis(bahmet_keyring),
    ?assert(is_pid(KeyringAfter)),
    ?assertNotEqual(KeyringBefore, KeyringAfter).

%% Fara radacina, nu pornim. Nu degradam elegant.
%%
%% Un sistem care isi genereaza singur radacina la fiecare boot nu poate
%% desface nimic din ce a cifrat inainte; unul care o persista langa
%% ciphertext nu protejeaza nimic. Refuzul e singura optiune onesta.
keyring_refuses_without_root(_Config) ->
    Saved = os:getenv("BAHMET_ROOT_KEY"),
    Trapping = process_flag(trap_exit, true),
    true = os:unsetenv("BAHMET_ROOT_KEY"),
    try
        ?assertMatch({error, {no_root_key, _}}, bahmet_keyring:start_link()),
        receive {'EXIT', _, _} -> ok after 200 -> ok end
    after
        true = os:putenv("BAHMET_ROOT_KEY", Saved),
        process_flag(trap_exit, Trapping)
    end.

%% Handle-ul e opac, dar `#Ref<>' identifica resursa in jurnale si ajuta un
%% atacator sa coreleze evenimente. Redactam din obisnuinta -- obiceiul e mai
%% sigur decat judecata caz cu caz.
keyring_redacts_root(_Config) ->
    {status, _Pid, _Mod, Items} = sys:get_status(bahmet_keyring),
    Formatted = lists:flatten(io_lib:format("~p", [Items])),
    ?assertNotEqual(nomatch, string:find(Formatted, "redacted")).

%%====================================================================

stop_sync(Sup) ->
    case is_process_alive(Sup) of
        false -> ok;
        true ->
            Ref = monitor(process, Sup),
            exit(Sup, shutdown),
            receive
                {'DOWN', Ref, process, Sup, _} -> ok
            after 5000 ->
                demonitor(Ref, [flush]),
                exit(Sup, kill),
                timer:sleep(100),
                ok
            end
    end.
