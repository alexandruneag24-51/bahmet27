%%%-------------------------------------------------------------------
%%% @doc Frontiera de custodie.
%%%
%%% `cargo test' acopera deja miezul criptografic in izolare. Aici testam ce
%%% Rust nu poate atinge singur: comportamentul la trecerea peste puntea NIF,
%%% cu BEAM viu, termeni Erlang si binare reale.
%%%
%%% Grupurile `aead' si `custody' ruleaza in paralel: fiecare caz isi faureste
%%% propriile chei si nu atinge stare comuna. Testele care pot rula in paralel
%%% sunt testele scrise curat -- daca doua cazuri se incurca, inseamna ca
%%% sistemul are stare partajata pe care nu am declarat-o.
%%% @end
%%%-------------------------------------------------------------------
-module(bahmet_vault_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([nif_loaded/1, entropy_answers/1,
         roundtrip_closes/1, fresh_nonce_each_seal/1,
         wrong_context_refuses/1, flipped_bit_refuses/1,
         wrong_key_refuses/1, single_failure_mode/1, refusal_is_value/1,
         shredded_key_refuses/1, envelope_closes/1, envelope_binds_realm/1,
         fingerprint_identifies_not_reveals/1, no_key_export/1]).

all() ->
    [{group, bridge}, {group, aead}, {group, custody}].

groups() ->
    [{bridge, [], [nif_loaded, entropy_answers]},
     {aead, [parallel], [roundtrip_closes, fresh_nonce_each_seal,
                         wrong_context_refuses, flipped_bit_refuses,
                         wrong_key_refuses, single_failure_mode,
                         refusal_is_value]},
     {custody, [parallel], [shredded_key_refuses, envelope_closes,
                            envelope_binds_realm,
                            fingerprint_identifies_not_reveals,
                            no_key_export]}].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(bahmet),
    {module, bahmet_vault} = code:ensure_loaded(bahmet_vault),
    Config.

end_per_suite(_Config) ->
    _ = application:stop(bahmet),
    ok.

%%====================================================================
%% Puntea
%%====================================================================

%% Stub-ul Erlang s-ar declansa cu `nif_not_loaded'. Daca o cheie reala se
%% intoarce cu metadate corecte, codul nativ a preluat controlul.
nif_loaded(_Config) ->
    ?assertEqual({module, bahmet_vault}, code:ensure_loaded(bahmet_vault)),
    Key = bahmet_vault:forge_key(1),
    ?assertMatch(#{generation := 1, uses := 0, destroyed := false},
                 bahmet_vault:key_status(Key)).

entropy_answers(_Config) ->
    ?assertEqual({ok, true}, bahmet_vault:entropy_health()).

%%====================================================================
%% AEAD
%%====================================================================

roundtrip_closes(_Config) ->
    Key = bahmet_vault:forge_key(1),
    Message = <<"secret care nu trebuie sa iasa">>,
    {ok, Sealed} = bahmet_vault:seal(Key, Message, <<"context">>),
    ?assertEqual({ok, Message}, bahmet_vault:unseal(Key, Sealed, <<"context">>)).

%% Cel mai important caz din suita, dupa `no_key_export'.
%%
%% Daca aceleasi date cifrate de doua ori dau acelasi ciphertext, cifrarea e
%% determinista: un atacator vede care mesaje se repeta, construieste un
%% dictionar si sparge sistemul fara sa atinga cheia. O suta de sigilari ale
%% aceluiasi text trebuie sa dea o suta de nonce-uri distincte.
fresh_nonce_each_seal(_Config) ->
    Key = bahmet_vault:forge_key(1),
    Sealed = [begin
                  {ok, S} = bahmet_vault:seal(Key, <<"identic">>, <<>>),
                  S
              end || _ <- lists:seq(1, 100)],
    Nonces = [N || <<N:24/binary, _/binary>> <- Sealed],
    ?assertEqual(100, length(lists:usort(Nonces))),
    ?assertEqual(100, length(lists:usort(Sealed))),
    ?assertEqual({ok, <<"identic">>}, bahmet_vault:unseal(Key, hd(Sealed), <<>>)).

wrong_context_refuses(_Config) ->
    Key = bahmet_vault:forge_key(1),
    {ok, Sealed} = bahmet_vault:seal(Key, <<"date">>, <<"corect">>),
    ?assertEqual({error, decrypt_failed},
                 bahmet_vault:unseal(Key, Sealed, <<"gresit">>)).

%% Fiecare pozitie din ciphertext, pe rand -- inclusiv nonce-ul.
%% `usort' care se prabuseste la un singur element ESTE invariantul:
%% orice bit atins, oriunde, produce exact acelasi refuz.
flipped_bit_refuses(_Config) ->
    Key = bahmet_vault:forge_key(1),
    {ok, Sealed} = bahmet_vault:seal(Key, <<"date destul de lungi ca sa conteze">>, <<>>),
    Results = [bahmet_vault:unseal(Key, flip(Sealed, I), <<>>)
               || I <- lists:seq(0, byte_size(Sealed) - 1)],
    ?assertEqual([{error, decrypt_failed}], lists:usort(Results)).

wrong_key_refuses(_Config) ->
    A = bahmet_vault:forge_key(1),
    B = bahmet_vault:forge_key(2),
    {ok, Sealed} = bahmet_vault:seal(A, <<"date">>, <<>>),
    ?assertEqual({error, decrypt_failed}, bahmet_vault:unseal(B, Sealed, <<>>)).

%% Patru cauze complet diferite, un singur raspuns. Daca s-ar distinge, un
%% atacator ar avea un oracol: intreaba repetat si afla, din care eroare
%% primeste, daca a ghicit cheia, contextul sau formatul.
single_failure_mode(_Config) ->
    K1 = bahmet_vault:forge_key(1),
    K2 = bahmet_vault:forge_key(2),
    {ok, Sealed} = bahmet_vault:seal(K1, <<"date">>, <<"aad">>),
    Causes = [bahmet_vault:unseal(K1, Sealed, <<"alt">>),
              bahmet_vault:unseal(K2, Sealed, <<"aad">>),
              bahmet_vault:unseal(K1, <<0, 1, 2>>, <<"aad">>),
              bahmet_vault:unseal(K1, <<>>, <<"aad">>)],
    ?assertEqual([{error, decrypt_failed}], lists:usort(Causes)).

%% Proprietatea anti-indisponibilitate.
%%
%% Refuzul trebuie sa fie o VALOARE intoarsa, nu o exceptie. Verificam asta
%% observand un proces separat: daca ar ridica, ar muri cu alt motiv decat
%% `normal'. Iar daca ar muri, oricine poate trimite ciphertext invalid la
%% nesfarsit ca sa omoare custozii unul cate unul, pana cand supervizorul
%% isi epuizeaza `intensity' si renunta.
refusal_is_value(_Config) ->
    Key = bahmet_vault:forge_key(1),
    {ok, Sealed} = bahmet_vault:seal(Key, <<"date">>, <<"aad">>),
    Parent = self(),
    {Worker, Ref} = spawn_monitor(
        fun() -> Parent ! {result, bahmet_vault:unseal(Key, Sealed, <<"alt">>)} end),
    receive
        {result, Result} -> ?assertEqual({error, decrypt_failed}, Result)
    after 2000 -> ct:fail(niciun_raspuns)
    end,
    receive
        {'DOWN', Ref, process, Worker, Reason} -> ?assertEqual(normal, Reason)
    after 2000 -> ct:fail(procesul_nu_s_a_incheiat)
    end.

%%====================================================================
%% Custodia
%%====================================================================

%% Crypto-shredding: distrugi cheia, datele devin zgomot fara a le atinge.
shredded_key_refuses(_Config) ->
    Key = bahmet_vault:forge_key(1),
    {ok, Sealed} = bahmet_vault:seal(Key, <<"date">>, <<>>),
    ok = bahmet_vault:shred(Key),
    ?assertEqual({error, key_destroyed}, bahmet_vault:unseal(Key, Sealed, <<>>)),
    ?assertEqual({error, key_destroyed}, bahmet_vault:seal(Key, <<"altceva">>, <<>>)),
    ?assertMatch(#{destroyed := true}, bahmet_vault:key_status(Key)).

%% Rotatia reimpacheteaza DEK-uri, nu recripteaza date. Aici verificam ca
%% un DEK renaste din plic identic cu el insusi -- amprenta o dovedeste.
envelope_closes(_Config) ->
    Kek = bahmet_vault:forge_key(0),
    Dek = bahmet_vault:forge_key(1),
    Payload = <<"un terabyte, simbolic">>,
    {ok, Sealed} = bahmet_vault:seal(Dek, Payload, <<>>),
    {ok, Wrapped} = bahmet_vault:wrap_key(Kek, Dek, <<"realm">>),
    Restored = bahmet_vault:unwrap_key(Kek, Wrapped, <<"realm">>, 1),
    ?assertEqual({ok, Payload}, bahmet_vault:unseal(Restored, Sealed, <<>>)),
    ?assertEqual(bahmet_vault:fingerprint(Dek), bahmet_vault:fingerprint(Restored)).

%% AAD-ul leaga criptografic contextul: un DEK impachetat pentru un domeniu
%% nu poate fi desfacut in altul, chiar cu KEK-ul corect.
envelope_binds_realm(_Config) ->
    Kek = bahmet_vault:forge_key(0),
    Dek = bahmet_vault:forge_key(1),
    {ok, Wrapped} = bahmet_vault:wrap_key(Kek, Dek, <<"realm-a">>),
    ?assertEqual({error, decrypt_failed},
                 bahmet_vault:unwrap_key(Kek, Wrapped, <<"realm-b">>, 1)).

fingerprint_identifies_not_reveals(_Config) ->
    A = bahmet_vault:forge_key(1),
    B = bahmet_vault:forge_key(1),
    Fa = bahmet_vault:fingerprint(A),
    ?assertEqual(8, byte_size(Fa)),
    ?assertNotEqual(Fa, bahmet_vault:fingerprint(B)),
    ?assertEqual(Fa, bahmet_vault:fingerprint(A)).

%% PROBA ABSENTEI -- proprietatea centrala a intregului proiect.
%%
%% Singurul mod de a o testa e sa verifici ca ceva NU exista. Daca vreo
%% functie din lista apare printre exporturi, frontiera de custodie s-a rupt
%% si tot restul devine teatru. Acest caz e paznicul care nu doarme in Faza 2.
no_key_export(_Config) ->
    Exports = [Name || {Name, _Arity} <- bahmet_vault:module_info(exports)],
    Forbidden = [export_key, key_bytes, reveal, material, dump, raw,
                 to_binary, unwrap_raw, secret],
    ?assertEqual([], [F || F <- Forbidden, lists:member(F, Exports)]),
    %% Singurul binar derivat vreodata dintr-o cheie are 8 octeti si e
    %% ireversibil. Nimic din modul nu produce 32.
    Key = bahmet_vault:forge_key(1),
    ?assertEqual(8, byte_size(bahmet_vault:fingerprint(Key))).

%%====================================================================

flip(Binary, Position) ->
    <<Prefix:Position/binary, Byte:8, Rest/binary>> = Binary,
    <<Prefix/binary, (Byte bxor 1):8, Rest/binary>>.
