%%%-------------------------------------------------------------------
%%% @doc Rotatia cheilor.
%%%
%%% Aici testam operatia care, gresita, nu esueaza zgomotos -- distruge date,
%%% tacut si ireversibil. Fiecare caz de mai jos corespunde unui mod concret
%%% in care rotatiile reale au pierdut date in sisteme reale.
%%% @end
%%%-------------------------------------------------------------------
-module(bahmet_rotation_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([derivation_survives_restart/1,
         rotation_preserves_every_secret/1,
         rotation_leaves_nobody_behind/1,
         rotation_advances_generation/1,
         stragglers_are_caught/1,
         old_generation_still_opens/1,
         retired_generation_halts_rotation/1,
         current_generation_cannot_retire/1,
         shredded_dek_is_unrecoverable/1]).

all() ->
    [derivation_survives_restart,
     rotation_preserves_every_secret,
     rotation_leaves_nobody_behind,
     rotation_advances_generation,
     stragglers_are_caught,
     old_generation_still_opens,
     shredded_dek_is_unrecoverable,
     current_generation_cannot_retire,
     %% Ultimul: retrage o generatie si strica setul pentru ce urmeaza.
     retired_generation_halts_rotation].

init_per_suite(Config) ->
    true = os:putenv("BAHMET_ROOT_KEY", lists:duplicate(64, $b)),
    Config.

end_per_suite(_Config) ->
    ok.

%% Depozit proaspat pentru fiecare caz: DETS pe disc supravietuieste altfel
%% dintr-un test in altul si transforma esecurile in mistere.
init_per_testcase(Case, Config) ->
    Dir = proplists:get_value(priv_dir, Config),
    File = filename:join(Dir, atom_to_list(Case) ++ ".dets"),
    ok = application:set_env(bahmet, dek_store_file, File),
    {ok, Sup} = bahmet_vault_sup:start_link(),
    unlink(Sup),
    [{sup, Sup} | Config].

end_per_testcase(_Case, Config) ->
    case proplists:get_value(sup, Config) of
        undefined -> ok;
        Sup -> stop_sync(Sup)
    end.

%%====================================================================

%% Piatra de temelie a intregii scheme.
%%
%% Daca subcheile nu s-ar deriva determinist, o rotatie cazuta la mijloc ar
%% pierde cheia tinta si, odata cu ea, tot ce apucase sa rescrie. Aici
%% verificam ca aceeasi radacina si aceeasi generatie dau aceeasi cheie,
%% peste doua handle-uri de radacina complet separate.
derivation_survives_restart(_Config) ->
    Material = binary:copy(<<7>>, 32),
    First = bahmet_vault:import_root(Material, 0),
    Second = bahmet_vault:import_root(Material, 0),
    Fingerprints = [bahmet_vault:fingerprint(bahmet_vault:derive_generation(R, 5))
                    || R <- [First, Second]],
    ?assertEqual(1, length(lists:usort(Fingerprints))),
    %% ...iar generatii diferite raman chei independente.
    ?assertNotEqual(
       bahmet_vault:fingerprint(bahmet_vault:derive_generation(First, 5)),
       bahmet_vault:fingerprint(bahmet_vault:derive_generation(First, 6))).

%% Proba care conteaza cel mai mult: dupa rotatie, fiecare secret cifrat
%% inainte de ea trebuie sa se desfaca la exact acelasi text.
rotation_preserves_every_secret(_Config) ->
    Secrets = [seal_one(N) || N <- lists:seq(1, 25)],
    ?assertEqual(25, length(Secrets)),
    _ = [bahmet_vault:shred(Dek) || {_Id, Dek, _Sealed} <- Secrets],

    {ok, Moved} = bahmet_rotation:rotate_now(),
    ?assertEqual(25, Moved),

    %% Redeschidem fiecare DEK -- acum prin KEK-ul generatiei noi -- si
    %% cerem exact textul de la inceput.
    _ = [begin
         {ok, Reopened} = bahmet_keyring:open(Id),
         ?assertEqual({ok, expected(Id)}, bahmet_vault:unseal(Reopened, Sealed, <<"ctx">>)),
         bahmet_vault:shred(Reopened)
     end || {Id, _Dek, Sealed} <- Secrets].

%% Un DEK ramas in urma e o bomba cu ceas: functioneaza pana cand cineva
%% retrage generatia veche, apoi datele lui dispar. `pending' gol e singura
%% dovada ca rotatia chiar s-a terminat.
rotation_leaves_nobody_behind(_Config) ->
    _ = [seal_one(N) || N <- lists:seq(1, 10)],
    Target = bahmet_keyring:generation() + 1,
    {ok, _} = bahmet_rotation:rotate_now(),
    ?assertEqual([], bahmet_dek_store:pending(Target, 100)),
    ?assertEqual(#{Target => 10}, bahmet_dek_store:tally()).

rotation_advances_generation(_Config) ->
    ?assertEqual(0, bahmet_keyring:generation()),
    {ok, _} = bahmet_rotation:rotate_now(),
    ?assertEqual(1, bahmet_keyring:generation()),
    {ok, _} = bahmet_rotation:rotate_now(),
    ?assertEqual(2, bahmet_keyring:generation()),
    %% Generatia persista in depozit, nu doar in memoria keyring-ului.
    ?assertEqual(2, bahmet_dek_store:generation()).

%% Calea de reluare.
%%
%% Un DEK ramas la o generatie mult mai veche -- pentru ca o rotatie
%% anterioara a cazut inainte sa ajunga la el -- trebuie prins de urmatoarea
%% rotatie, nu ignorat. `pending' filtreaza dupa „nu e la tinta", nu dupa
%% „e la tinta minus unu", tocmai ca sa acopere cazul asta.
stragglers_are_caught(_Config) ->
    {ok, _} = bahmet_rotation:rotate_now(),
    {ok, _} = bahmet_rotation:rotate_now(),
    ?assertEqual(2, bahmet_keyring:generation()),

    %% Fabricam un intarziat: un DEK impachetat cu KEK-ul generatiei 0,
    %% inregistrat ca atare, in vreme ce sistemul e la generatia 2.
    {ok, Ancient} = bahmet_keyring:key_for(0),
    Dek = bahmet_vault:forge_key(0),
    {ok, Wrapped} = bahmet_vault:wrap_key(Ancient, Dek, <<"straggler">>),
    Id = bahmet_vault:fingerprint(Dek),
    ok = bahmet_dek_store:issue(Id, 0, {Wrapped, <<"straggler">>}),
    bahmet_vault:shred(Dek),

    ?assertMatch(#{0 := 1}, bahmet_dek_store:tally()),
    {ok, Moved} = bahmet_rotation:rotate_now(),
    ?assertEqual(1, Moved),
    ?assertEqual(#{3 => 1}, bahmet_dek_store:tally()),
    %% Si chiar se deschide dupa toata calatoria.
    ?assertMatch({ok, _}, bahmet_keyring:open(Id)).

%% In timpul rotatiei, ambele generatii trebuie sa desfaca. Testam ca
%% generatia veche ramane servita si dupa promovare -- plasa de siguranta
%% pentru orice DEK scapat din vedere.
old_generation_still_opens(_Config) ->
    {Id, Dek, Sealed} = seal_one(1),
    bahmet_vault:shred(Dek),
    {ok, _} = bahmet_rotation:rotate_now(),

    Live = bahmet_keyring:live(),
    ?assertEqual(1, maps:get(current, Live)),
    ?assert(lists:member(0, maps:get(cached, Live))),
    ?assertEqual([], maps:get(retired, Live)),

    {ok, Reopened} = bahmet_keyring:open(Id),
    ?assertEqual({ok, expected(Id)}, bahmet_vault:unseal(Reopened, Sealed, <<"ctx">>)).

%% Crypto-shredding la nivelul datelor unui utilizator: stergi DEK-ul din
%% catalog, iar ciphertext-ul devine zgomot fara sa fie atins.
shredded_dek_is_unrecoverable(_Config) ->
    {Id, Dek, _Sealed} = seal_one(1),
    bahmet_vault:shred(Dek),
    ?assertMatch({ok, _}, bahmet_keyring:open(Id)),
    ok = bahmet_dek_store:forget(Id),
    ?assertEqual({error, not_found}, bahmet_keyring:open(Id)),
    %% Nici rotatia nu-l mai vede -- nu mai exista nimic de mutat.
    {ok, 0} = bahmet_rotation:rotate_now().

%% Retragerea generatiei curente ar face sistemul incapabil sa-si deschida
%% propriile chei noi. E o autodistrugere pe care nimeni nu o cere
%% intentionat, deci nu o permitem din greseala.
current_generation_cannot_retire(_Config) ->
    Current = bahmet_keyring:generation(),
    ?assertEqual({error, cannot_retire_current}, bahmet_keyring:retire(Current)).

%% Daca un DEK a ramas la o generatie deja retrasa, datele lui sunt pierdute.
%% Rotatia trebuie sa se OPREASCA, nu sa sara peste el: un esec zgomotos azi
%% e infinit mai bun decat o descoperire tacuta peste sase luni.
retired_generation_halts_rotation(_Config) ->
    {ok, Ancient} = bahmet_keyring:key_for(0),
    Dek = bahmet_vault:forge_key(0),
    {ok, Wrapped} = bahmet_vault:wrap_key(Ancient, Dek, <<"orfan">>),
    Id = bahmet_vault:fingerprint(Dek),
    ok = bahmet_dek_store:issue(Id, 0, {Wrapped, <<"orfan">>}),
    bahmet_vault:shred(Dek),

    {ok, _} = bahmet_rotation:rotate_now(),      % 0 -> 1, orfanul se muta
    ok = bahmet_dek_store:commit(Id, 0, Wrapped),% il impingem inapoi la 0
    ok = bahmet_keyring:retire(0),

    ?assertMatch({error, {generation_retired, 0, _}}, bahmet_rotation:rotate_now()),
    %% Si, esential: generatia NU a avansat. Nimic nu a fost promovat peste
    %% o rotatie incompleta.
    ?assertEqual(1, bahmet_keyring:generation()).

%%====================================================================
%% Ajutoare
%%====================================================================

%% Un secret al carui text derivă din identitatea proprie, ca sa putem
%% verifica dupa rotatie ca fiecare DEK a deschis exact ce trebuia -- nu doar
%% „ceva". O rotatie care amesteca doua chei ar trece un test mai slab.
seal_one(_N) ->
    {ok, Id, Dek} = bahmet_keyring:issue(<<"realm">>),
    {ok, Sealed} = bahmet_vault:seal(Dek, expected(Id), <<"ctx">>),
    {Id, Dek, Sealed}.

expected(Id) -> <<"secret pentru ", Id/binary>>.

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
