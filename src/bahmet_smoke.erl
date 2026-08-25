%%%-------------------------------------------------------------------
%%% @doc bahmet_smoke -- Probă rapidă.
%%%
%%% Nu e o suită de teste (aceea vine în Faza 2, cu Common Test). E un
%%% detector de fum: verifică invariantele care, dacă se rup, fac restul
%%% sistemului o iluzie.
%%%
%%%   bahmet_smoke:run().    -- 12 invariante criptografice
%%%   bahmet_smoke:tree().   -- gradientul de iertare din arbore
%%%
%%% Fiecare probă răspunde la o singură întrebare, iar întrebările sunt
%%% alese pentru ce ar însemna dacă răspunsul ar fi „nu".
%%% @end
%%%-------------------------------------------------------------------
-module(bahmet_smoke).

-export([run/0, tree/0]).

%%====================================================================
%% Probele criptografice
%%====================================================================

-spec run() -> ok | {error, non_neg_integer()}.
run() ->
    io:format("~n=== Bahmet 27 / seiful ===~n~n"),
    Checks = [
        {"NIF-ul vault e încărcat",              fun c_loaded/0},
        {"entropia răspunde",                    fun c_entropy/0},
        {"sigilare -> desfacere se închid",      fun c_roundtrip/0},
        {"nonce aleator: două sigilări diferă",  fun c_nondeterministic/0},
        {"context greșit -> refuz",              fun c_bad_context/0},
        {"un bit schimbat -> refuz",             fun c_tampered/0},
        {"cheie greșită -> refuz",               fun c_wrong_key/0},
        {"UN SINGUR mod de eșec",                fun c_single_failure/0},
        {"refuzul e valoare, nu prăbușire",      fun c_refusal_is_value/0},
        {"cheia distrusă refuză orice",          fun c_shred/0},
        {"plicul: wrap -> unwrap se închid",     fun c_envelope/0},
        {"amprenta e stabilă și nu dezvăluie",   fun c_fingerprint/0},
        {"NU EXISTĂ export de cheie",            fun c_no_export/0}
    ],
    Outcomes = [one(Name, Fun) || {Name, Fun} <- Checks],
    Failed = length([bad || false <- Outcomes]),
    io:format("~n~p/~p au trecut~n~n", [length(Outcomes) - Failed, length(Outcomes)]),
    case Failed of
        0 -> ok;
        N -> {error, N}
    end.

one(Name, Fun) ->
    try Fun() of
        ok ->
            io:format("  [ok]   ~ts~n", [Name]),
            true;
        Other ->
            io:format("  [EȘEC] ~ts~n         -> ~p~n", [Name, Other]),
            false
    catch
        Class:Reason ->
            io:format("  [EȘEC] ~ts~n         -> ~p:~p~n", [Name, Class, Reason]),
            false
    end.

%% Întoarce motivul refuzului, sau {unexpected_success, V} dacă a reușit.
%%
%% Rustler distinge două feluri de eroare:
%%   Error::Term(T)      -> ÎNTOARCE {error, T} ca valoare obișnuită
%%   Error::RaiseTerm(T) -> ridică excepție
%%
%% bahmet_vault o folosește pe prima, deliberat. Dacă un ciphertext malformat
%% ar ridica excepție, un atacator care trimite gunoi repetat ar prăbuși
%% custozii în lanț până la epuizarea lui `intensity` din supervizor --
%% indisponibilitate provocată cu date invalide. Un refuz e o valoare.
%%
%% Prindem și excepțiile, ca proba să rămână corectă dacă cineva schimbă
%% vreodată varianta de eroare din Rust.
reason(Fun) ->
    try Fun() of
        {error, Why} -> Why;
        Value -> {unexpected_success, Value}
    catch
        _Class:Why -> Why
    end.

%%--------------------------------------------------------------------

c_loaded() ->
    {module, bahmet_vault} = code:ensure_loaded(bahmet_vault),
    ok.

c_entropy() ->
    %% `false` aici înseamnă sursă CSPRNG ruptă -- caz în care nicio cheie
    %% generată vreodată de sistem nu valorează nimic.
    {ok, true} = bahmet_vault:entropy_health(),
    ok.

c_roundtrip() ->
    K = bahmet_vault:forge_key(1),
    Msg = <<"secret care nu trebuie sa iasa">>,
    {ok, Sealed} = bahmet_vault:seal(K, Msg, <<"context">>),
    {ok, Msg} = bahmet_vault:unseal(K, Sealed, <<"context">>),
    ok.

%% Cea mai importantă probă din listă după `c_no_export`.
%%
%% Dacă aceleași date cifrate de două ori produc același ciphertext,
%% cifrarea e DETERMINISTĂ -- un atacator vede care mesaje se repetă,
%% construiește un dicționar și sparge sistemul fără să atingă cheia.
%% Aici verificăm că nonce-ul e cu adevărat proaspăt la fiecare apel.
c_nondeterministic() ->
    K = bahmet_vault:forge_key(1),
    {ok, A} = bahmet_vault:seal(K, <<"identic">>, <<>>),
    {ok, B} = bahmet_vault:seal(K, <<"identic">>, <<>>),
    true = A =/= B,
    %% ...și totuși ambele se desfac la același text.
    {ok, <<"identic">>} = bahmet_vault:unseal(K, A, <<>>),
    {ok, <<"identic">>} = bahmet_vault:unseal(K, B, <<>>),
    ok.

c_bad_context() ->
    K = bahmet_vault:forge_key(1),
    {ok, S} = bahmet_vault:seal(K, <<"date">>, <<"corect">>),
    decrypt_failed = reason(fun() -> bahmet_vault:unseal(K, S, <<"gresit">>) end),
    ok.

c_tampered() ->
    K = bahmet_vault:forge_key(1),
    {ok, S} = bahmet_vault:seal(K, <<"date">>, <<>>),
    decrypt_failed = reason(fun() -> bahmet_vault:unseal(K, flip(S), <<>>) end),
    ok.

c_wrong_key() ->
    A = bahmet_vault:forge_key(1),
    B = bahmet_vault:forge_key(2),
    {ok, S} = bahmet_vault:seal(A, <<"date">>, <<>>),
    decrypt_failed = reason(fun() -> bahmet_vault:unseal(B, S, <<>>) end),
    ok.

%% Trei cauze complet diferite trebuie să producă ACELAȘI atom.
%%
%% Dacă ar diferi, un atacator ar avea un oracol: întreabă sistemul
%% în mod repetat și află, din care eroare primește, dacă a ghicit
%% cheia, contextul sau formatul. Ambiguitatea de aici este o funcție.
c_single_failure() ->
    K1 = bahmet_vault:forge_key(1),
    K2 = bahmet_vault:forge_key(2),
    {ok, S} = bahmet_vault:seal(K1, <<"date">>, <<"aad">>),
    R1 = reason(fun() -> bahmet_vault:unseal(K1, S, <<"alt">>) end),
    R2 = reason(fun() -> bahmet_vault:unseal(K2, S, <<"aad">>) end),
    R3 = reason(fun() -> bahmet_vault:unseal(K1, <<0, 1, 2>>, <<"aad">>) end),
    true = (R1 =:= R2) andalso (R2 =:= R3),
    decrypt_failed = R1,
    ok.

%% Crypto-shredding: distrugi cheia, datele devin zgomot.
%% Proprietatea anti-DoS.
%%
%% Un refuz trebuie să fie un `{error, _}` întors, nu o excepție. Altfel,
%% oricine poate trimite ciphertext invalid la nesfârșit ca să omoare
%% custozii unul câte unul, până când supervizorul renunță.
c_refusal_is_value() ->
    K = bahmet_vault:forge_key(1),
    {ok, S} = bahmet_vault:seal(K, <<"date">>, <<"aad">>),
    {error, decrypt_failed} = bahmet_vault:unseal(K, S, <<"alt">>),
    ok.

c_shred() ->
    K = bahmet_vault:forge_key(1),
    {ok, S} = bahmet_vault:seal(K, <<"date">>, <<>>),
    ok = bahmet_vault:shred(K),
    key_destroyed = reason(fun() -> bahmet_vault:unseal(K, S, <<>>) end),
    ok.

%% Cifrarea cu plic: rotația reîmpachetează DEK-uri, nu recriptează date.
c_envelope() ->
    Kek = bahmet_vault:forge_key(0),
    Dek = bahmet_vault:forge_key(1),
    Payload = <<"un terabyte, simbolic">>,
    {ok, Sealed} = bahmet_vault:seal(Dek, Payload, <<>>),
    {ok, Wrapped} = bahmet_vault:wrap_key(Kek, Dek, <<"realm">>),
    %% DEK-ul renaște din plic, fără ca octeții lui să atingă vreodată BEAM.
    Restored = bahmet_vault:unwrap_key(Kek, Wrapped, <<"realm">>, 1),
    {ok, Payload} = bahmet_vault:unseal(Restored, Sealed, <<>>),
    ok.

c_fingerprint() ->
    A = bahmet_vault:forge_key(1),
    B = bahmet_vault:forge_key(1),
    Fa = bahmet_vault:fingerprint(A),
    8 = byte_size(Fa),
    true = Fa =/= bahmet_vault:fingerprint(B),   % chei diferite, amprente diferite
    Fa = bahmet_vault:fingerprint(A),            % stabilă: utilizabilă în audit
    ok.

%% PROBA ABSENȚEI.
%%
%% Aceasta e proprietatea centrală de securitate a întregului proiect, iar
%% singurul mod de a o testa este să verifici că ceva NU există. Dacă vreo
%% funcție din listă apare printre exporturi, frontiera de custodie s-a rupt
%% și tot restul e teatru.
c_no_export() ->
    Exports = [Name || {Name, _Arity} <- bahmet_vault:module_info(exports)],
    Forbidden = [export_key, key_bytes, reveal, material, dump, raw, to_binary],
    [] = [F || F <- Forbidden, lists:member(F, Exports)],
    ok.

flip(Bin) ->
    Head = byte_size(Bin) - 1,
    <<Prefix:Head/binary, Last:8>> = Bin,
    <<Prefix/binary, (Last bxor 1):8>>.

%%====================================================================
%% Arborele: gradientul de iertare
%%====================================================================

-spec tree() -> ok | {error, term()}.
tree() ->
    case os:getenv("BAHMET_ROOT_KEY") of
        false ->
            io:format("~nBAHMET_ROOT_KEY nu e setat. Ieși cu q(). și rulează:~n~n"
                      "  export BAHMET_ROOT_KEY=$(openssl rand -hex 32)~n"
                      "  ERL_CRASH_DUMP_SECONDS=0 rebar3 shell~n~n"),
            {error, no_root_key};
        _ ->
            io:format("~n=== Arborele seifului ===~n~n"),
            {ok, Sup} = bahmet_vault_sup:start_link(),
            %% Dezlegăm, ca prăbușirile din probă să nu omoare shell-ul.
            unlink(Sup),
            timer:sleep(150),
            Result = gradient(),
            exit(Sup, shutdown),
            timer:sleep(100),
            Result
    end.

gradient() ->
    Names = [bahmet_entropy, bahmet_keyring, bahmet_rotation, bahmet_sentinel],
    Before = [whereis(N) || N <- Names],
    io:format("  pornite: ~p~n~n", [Before]),

    %% ── Santinela: cea mai iertată ─────────────────────────────────
    %% Un paznic care oprește tot când se împiedică e mai periculos decât
    %% lipsa lui. Căderea ei nu trebuie să atingă pe nimeni.
    CoreBefore = lists:sublist(Before, 3),
    exit(whereis(bahmet_sentinel), kill),
    timer:sleep(400),
    CoreAfter = [whereis(N) || N <- lists:sublist(Names, 3)],
    ok = report("căderea santinelei nu atinge pe nimeni", CoreAfter =:= CoreBefore),

    %% ── Entropia: temelia, zero iertare ────────────────────────────
    %% Cheile create după o sursă suspectă sunt suspecte, iar cei care le
    %% țin nu au cum să afle singuri. `rest_for_one` decide pentru ei.
    KeyringBefore = whereis(bahmet_keyring),
    exit(whereis(bahmet_entropy), kill),
    timer:sleep(700),
    KeyringAfter = whereis(bahmet_keyring),
    ok = report("căderea entropiei refondează custodia",
                is_pid(KeyringAfter) andalso KeyringAfter =/= KeyringBefore),

    io:format("~n"),
    ok.

report(What, true) ->
    io:format("  [ok]   ~ts~n", [What]), ok;
report(What, false) ->
    io:format("  [EȘEC] ~ts~n", [What]), ok.
