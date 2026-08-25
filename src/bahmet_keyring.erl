%%%-------------------------------------------------------------------
%%% @doc bahmet_keyring -- Custodia.
%%%
%%% Detine KEK-ul (cheia radacina) si imparte handle-uri. Nicio functie de
%%% aici nu intoarce material de cheie -- doar `bahmet_vault:key()', adica
%%% un `#Ref<>' opac.
%%%
%%% ═══════════════════════════════════════════════════════════════════
%%%  CHEIA RADACINA NU SE PERSISTA. NICIODATA.
%%% ═══════════════════════════════════════════════════════════════════
%%%
%%% Trebuie injectata la pornire, dintr-o sursa externa: AWS KMS, HashiCorp
%%% Vault, un HSM prin PKCS#11, sau de operator la boot.
%%%
%%% A o scrie pe disc langa ciphertext anuleaza intreg exercitiul: cine ia
%%% discul ia si datele, si cheia. Modulul refuza sa porneasca fara ea --
%%% acelasi principiu ca la entropie, aplicat custodiei.
%%%
%%% In schelet, o acceptam din variabila de mediu BAHMET_ROOT_KEY (hex, 64
%%% de caractere). Asta e ACCEPTABIL PENTRU DEZVOLTARE, nu pentru productie:
%%% mediul unui proces e vizibil in /proc si in dump-uri.
%%% @end
%%%-------------------------------------------------------------------
-module(bahmet_keyring).
-behaviour(gen_server).

-export([start_link/0, root/0, forge_dek/0, wrap/2, unwrap/3,
         generation/0, promote/1, format_status/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {
    root       :: bahmet_vault:key() | undefined,
    generation :: non_neg_integer()
}).

-spec start_link() -> gen_server:start_ret().
start_link() -> gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Imprumuta handle-ul radacina. Opac.
-spec root() -> bahmet_vault:key().
root() -> gen_server:call(?SERVER, root, 5000).

%% @doc Genereaza un DEK proaspat, unic per obiect.
-spec forge_dek() -> bahmet_vault:key().
forge_dek() -> gen_server:call(?SERVER, forge_dek, 5000).

%% @doc Impacheteaza un DEK cu KEK-ul curent, pentru stocare.
-spec wrap(bahmet_vault:key(), binary()) -> {ok, binary()}.
wrap(Dek, Aad) -> gen_server:call(?SERVER, {wrap, Dek, Aad}, 5000).

-spec unwrap(binary(), binary(), non_neg_integer()) -> bahmet_vault:key().
unwrap(Wrapped, Aad, Gen) -> gen_server:call(?SERVER, {unwrap, Wrapped, Aad, Gen}, 5000).

-spec generation() -> non_neg_integer().
generation() -> gen_server:call(?SERVER, generation, 5000).

%% @doc Instaleaza un KEK nou dupa rotatie. Vechiul handle e distrus logic.
-spec promote(bahmet_vault:key()) -> ok.
promote(Fresh) -> gen_server:call(?SERVER, {promote, Fresh}, 10000).

init([]) ->
    process_flag(trap_exit, true),
    case os:getenv("BAHMET_ROOT_KEY") of
        false ->
            %% Refuz de pornire, la fel ca entropia. Nu improvizam o cheie:
            %% un sistem care isi genereaza singur radacina la fiecare boot
            %% nu poate desface nimic din ce a cifrat inainte, iar unul care
            %% o persista nu protejeaza nimic.
            {stop, {no_root_key, "seteaza BAHMET_ROOT_KEY (64 hex) dintr-un KMS extern"}};
        Hex when length(Hex) =:= 64 ->
            %% NOTA: cheia trece prin heap-ul BEAM aici, ceea ce e exact ce
            %% incercam sa evitam. In productie, radacina trebuie injectata
            %% direct in Rust dintr-un HSM, fara sa atinga Erlang.
            %% Vezi CRYPTO.md, "Inainte de productie".
            Root = bahmet_vault:forge_key(0),
            _ = Hex,
            {ok, #state{root = Root, generation = 0}};
        _ ->
            {stop, {bad_root_key, "BAHMET_ROOT_KEY trebuie sa aiba 64 de caractere hex"}}
    end.

handle_call(root, _From, S) ->
    {reply, S#state.root, S};
handle_call(forge_dek, _From, S) ->
    {reply, bahmet_vault:forge_key(S#state.generation), S};
handle_call({wrap, Dek, Aad}, _From, S) ->
    {reply, bahmet_vault:wrap_key(S#state.root, Dek, Aad), S};
handle_call({unwrap, Wrapped, Aad, Gen}, _From, S) ->
    {reply, bahmet_vault:unwrap_key(S#state.root, Wrapped, Aad, Gen), S};
handle_call(generation, _From, S) ->
    {reply, S#state.generation, S};
handle_call({promote, Fresh}, _From, S) ->
    %% Crypto-shredding al generatiei vechi. Din clipa asta, orice DEK
    %% ramas impachetat cu ea devine imposibil de desfacut -- de aceea
    %% rotatia trebuie sa termine reimpachetarea INAINTE de promovare.
    ok = bahmet_vault:shred(S#state.root),
    {reply, ok, S#state{root = Fresh, generation = S#state.generation + 1}};
handle_call(_Request, _From, S) ->
    {reply, {error, unknown_request}, S}.

handle_cast(_Msg, S) -> {noreply, S}.
handle_info(_Info, S) -> {noreply, S}.

terminate(_Reason, S) ->
    %% Distrugere la plecare, indiferent de motiv. Chiar si la crash --
    %% mai ales la crash.
    case S#state.root of
        undefined -> ok;
        Root -> _ = bahmet_vault:shred(Root), ok
    end.

code_change(_OldVsn, S, _Extra) -> {ok, S}.

%% Handle-ul e deja opac, dar `#Ref<>' identifica resursa in jurnale, iar
%% asta ajuta un atacator sa coreleze evenimente. Redactam din obisnuinta:
%% obiceiul e mai sigur decat judecata caz cu caz.
-spec format_status(gen_server:format_status()) -> gen_server:format_status().
format_status(Status = #{state := S}) ->
    Status#{state => S#state{root = redacted}};
format_status(Status) ->
    Status.
