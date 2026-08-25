%%%-------------------------------------------------------------------
%%% @doc bahmet_vault -- Puntea catre umbra.
%%%
%%% Vocea Focului: imperativa, scurta, cu termen. Fiecare functie de aici
%%% COMANDA. Niciuna nu poate obliga Apa sa dezvaluie.
%%%
%%% ═══════════════════════════════════════════════════════════════════
%%%  CITESTE LISTA DE EXPORTURI. CE NU E ACOLO ESTE PROIECTAREA.
%%% ═══════════════════════════════════════════════════════════════════
%%%
%%% Nu exista `export_key`. Nu exista `key_bytes`. Nu exista `reveal`.
%%% Erlang primeste un `#Ref<>` opac si rezultate -- niciodata material.
%%%
%%% Nu e o conventie de echipa pe care cineva o poate uita intr-un pull
%%% request. Functiile nu exista in Rust, deci nu pot fi apelate de aici,
%%% deci nu pot fi expuse mai departe. Proprietatea se propaga in sus prin
%%% absenta, nu prin disciplina.
%%%
%%% Motivul, pe scurt (detalii in CRYPTO.md): binarele Erlang peste 64 de
%%% octeti sunt numarate prin referinte, copiate liber si colectate
%%% nedeterminist. Nu poti sterge sigur un binar din memoria BEAM. O cheie
%%% ajunsa aici ar exista, multiplicata, in locuri necontrolabile.
%%% @end
%%%-------------------------------------------------------------------
-module(bahmet_vault).

-export([entropy_health/0,
         forge_key/1,
         fingerprint/1,
         key_status/1,
         shred/1,
         seal/3,
         unseal/3,
         wrap_key/3,
         unwrap_key/4]).

-nifs([entropy_health/0, forge_key/1, fingerprint/1, key_status/1, shred/1,
       seal/3, unseal/3, wrap_key/3, unwrap_key/4]).

-on_load(init/0).

-define(APPNAME, bahmet).
-define(LIBNAME, "libbahmet_vault").

%% Un handle de cheie. Opac prin constructie: BEAM il reprezinta ca
%% referinta si nu are nicio cale de a-i inspecta continutul.
-opaque key() :: reference().
-export_type([key/0]).

%%====================================================================
%% Entropie
%%====================================================================

%% @doc Verifica sursa de entropie. `false' inseamna sursa rupta.
%%
%% Apelat de bahmet_entropy la pornire. Daca intoarce `false', sistemul
%% NU porneste. Nu degradam elegant: o cheie din entropie proasta e o
%% iluzie de securitate, adica mai rea decat lipsa securitatii, fiindca
%% produce incredere nemeritata.
-spec entropy_health() -> {ok, boolean()} | {error, entropy_unavailable}.
entropy_health() -> erlang:nif_error(nif_not_loaded).

%%====================================================================
%% Ciclul de viata al cheilor
%%====================================================================

-spec forge_key(Generation :: non_neg_integer()) ->
          key() | {error, entropy_unavailable}.
forge_key(_Generation) -> erlang:nif_error(nif_not_loaded).

%% @doc Amprenta publica, 8 octeti. Sigura de pus in jurnale.
%% Permite sa spui CARE cheie a fost folosita, fara sa spui CE cheie e.
-spec fingerprint(key()) -> binary().
fingerprint(_Key) -> erlang:nif_error(nif_not_loaded).

%% @doc Metadate pentru santinela: forme, niciodata continut.
-spec key_status(key()) ->
          #{generation := non_neg_integer(),
            uses       := non_neg_integer(),
            destroyed  := boolean()}.
key_status(_Key) -> erlang:nif_error(nif_not_loaded).

%% @doc Crypto-shredding. Distrugi cheia, datele devin zgomot.
%%
%% Singura stergere care functioneaza peste backup-uri, replici si
%% wear-leveling: nu atingi datele deloc, le faci imposibil de citit.
%% "Uita-ma" devenit executabil, ireversibil, verificabil.
-spec shred(key()) -> ok.
shred(_Key) -> erlang:nif_error(nif_not_loaded).

%%====================================================================
%% Cifrare
%%====================================================================

%% @doc Sigileaza. Intoarce `nonce || ciphertext || tag'.
%%
%% `Aad' e autentificat dar NU cifrat. Pune acolo identificatori, versiuni
%% si contoare anti-replay: legarea criptografica a contextului impiedica
%% mutarea unui ciphertext valid intr-un context unde ar insemna altceva.
-spec seal(key(), Plaintext :: binary(), Aad :: binary()) ->
          {ok, binary()} | {error, key_destroyed | entropy_unavailable}.
seal(_Key, _Plaintext, _Aad) -> erlang:nif_error(nif_not_loaded).

%% @doc Desface. Intoarce `{error, decrypt_failed}' la ORICE esec.
%%
%% Cheie gresita, ciphertext modificat, Aad nepotrivit -- toate produc
%% aceeasi eroare. Nu o rafina in mesaje distincte: ai reconstrui exact
%% oracolul pe care Rust il refuza.
%%
%% Refuzul e o VALOARE intoarsa, nu o exceptie. Distinctia e o proprietate
%% de securitate: daca ar ridica, oricine poate trimite ciphertext invalid
%% la nesfarsit ca sa omoare custozii unul cate unul, pana cand supervizorul
%% isi epuizeaza `intensity' si renunta. Datele ostile nu au voie sa devina
%% indisponibilitate.
-spec unseal(key(), Sealed :: binary(), Aad :: binary()) ->
          {ok, binary()} | {error, decrypt_failed | key_destroyed}.
unseal(_Key, _Sealed, _Aad) -> erlang:nif_error(nif_not_loaded).

%%====================================================================
%% Cifrare cu plic
%%====================================================================

%% @doc Impacheteaza DEK-ul cu KEK-ul, pentru stocare.
-spec wrap_key(Kek :: key(), Dek :: key(), Aad :: binary()) ->
          {ok, binary()} | {error, key_destroyed | entropy_unavailable}.
wrap_key(_Kek, _Dek, _Aad) -> erlang:nif_error(nif_not_loaded).

%% @doc Desface un DEK impachetat, direct intr-un handle nou.
%% Materialul nu devine niciodata termen Erlang.
-spec unwrap_key(Kek :: key(), Wrapped :: binary(), Aad :: binary(),
                 Generation :: non_neg_integer()) ->
          key() | {error, decrypt_failed | bad_key_length | key_destroyed}.
unwrap_key(_Kek, _Wrapped, _Aad, _Generation) -> erlang:nif_error(nif_not_loaded).

%%====================================================================
%% Incarcare
%%====================================================================

init() ->
    SoName =
        case code:priv_dir(?APPNAME) of
            {error, bad_name} ->
                case filelib:is_dir(filename:join("..", "priv")) of
                    true  -> filename:join(["..", "priv", ?LIBNAME]);
                    false -> filename:join("priv", ?LIBNAME)
                end;
            Dir ->
                filename:join(Dir, ?LIBNAME)
        end,
    erlang:load_nif(SoName, 0).
