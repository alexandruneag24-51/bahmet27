%%%-------------------------------------------------------------------
%%% @doc bahmet_keyring -- Custodia si generatiile.
%%%
%%% ═══════════════════════════════════════════════════════════════════
%%%  RADACINA NU SE ROTESTE. SUBCHEILE SE ROTESC.
%%% ═══════════════════════════════════════════════════════════════════
%%%
%%% Radacina vine dintr-un HSM/KMS si ramane aceeasi. Ce se roteste sunt
%%% subcheile derivate din ea:
%%%
%%%     KEK_n = HKDF-SHA256(radacina, "kek" || n)
%%%
%%% Alegerea asta nu e stilistica -- e conditia ca rotatia sa fie
%%% recuperabila. O cheie de generatie generata ALEATOR si pierduta la un
%%% crash ar distruge definitiv tot ce apucase sa rescrie. Una DERIVATA poate
%%% fi re-obtinuta oricand, pe orice masina, dupa orice repornire.
%%%
%%% Consecinta directa: o rotatie intrerupta se reia singura. Nu exista
%%% jurnal de progres de tinut si de mentinut corect, fiindca starea e
%%% recalculabila. Ce nu memorezi nu se poate desincroniza.
%%%
%%% ═══════════════════════════════════════════════════════════════════
%%%  DESPRE `retire/1'
%%% ═══════════════════════════════════════════════════════════════════
%%%
%%% Retragerea unei generatii e o POLITICA, nu o distrugere criptografica:
%%% cheia poate fi re-derivata oricand din radacina. Keyring-ul refuza sa o
%%% mai serveasca; matematica nu a uitat nimic.
%%%
%%% Spun asta explicit fiindca e exact genul de lucru pe care un cititor
%%% grabit il presupune mai puternic decat este. Crypto-shredding real al
%%% datelor unui utilizator se face distrugand DEK-ul lui, nu KEK-ul.
%%% @end
%%%-------------------------------------------------------------------
-module(bahmet_keyring).
-behaviour(gen_server).

-export([start_link/0,
         generation/0, key_for/1, current/0,
         issue/1, open/1,
         stage/1, promote/1, retire/1, live/0,
         format_status/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {
    root       :: bahmet_vault:key() | redacted,
    current    :: non_neg_integer(),
    keks       :: #{non_neg_integer() => bahmet_vault:key()},
    retired    :: [non_neg_integer()]
}).

%%====================================================================
%% API
%%====================================================================

-spec start_link() -> gen_server:start_ret().
start_link() -> gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec generation() -> non_neg_integer().
generation() -> gen_server:call(?SERVER, generation, 5000).

%% @doc Subcheia unei generatii. Derivata la cerere, memorata dupa aceea.
-spec key_for(non_neg_integer()) ->
          {ok, bahmet_vault:key()} | {error, retired}.
key_for(Generation) -> gen_server:call(?SERVER, {key_for, Generation}, 10000).

-spec current() -> {non_neg_integer(), bahmet_vault:key()}.
current() -> gen_server:call(?SERVER, current, 5000).

%% @doc Faureste un DEK, il impacheteaza cu KEK-ul curent, il inregistreaza.
%% Intoarce identitatea si handle-ul deschis, gata de folosit.
-spec issue(Aad :: binary()) -> {ok, binary(), bahmet_vault:key()} | {error, term()}.
issue(Aad) when is_binary(Aad) -> gen_server:call(?SERVER, {issue, Aad}, 15000).

%% @doc Redeschide un DEK inregistrat, cu KEK-ul generatiei lui.
-spec open(Id :: binary()) -> {ok, bahmet_vault:key()} | {error, term()}.
open(Id) when is_binary(Id) -> gen_server:call(?SERVER, {open, Id}, 15000).

%% @doc Pune o generatie la dispozitie FARA sa o faca curenta.
%%
%% Rotatia apeleaza asta inainte sa rescrie ceva: din clipa aceea ambele
%% generatii pot desface, ceea ce e conditia ca o cadere la mijloc sa lase
%% sistemul lizibil.
-spec stage(non_neg_integer()) -> {ok, bahmet_vault:key()}.
stage(Generation) -> gen_server:call(?SERVER, {stage, Generation}, 10000).

%% @doc Muta generatia curenta. Se apeleaza DUPA ce rescrierea s-a incheiat.
-spec promote(non_neg_integer()) -> ok.
promote(Generation) -> gen_server:call(?SERVER, {promote, Generation}, 10000).

%% @doc Refuza sa mai serveasca o generatie. Politica, nu distrugere.
-spec retire(non_neg_integer()) -> ok | {error, cannot_retire_current}.
retire(Generation) -> gen_server:call(?SERVER, {retire, Generation}, 10000).

-spec live() -> #{current := non_neg_integer(),
                  cached := [non_neg_integer()],
                  retired := [non_neg_integer()]}.
live() -> gen_server:call(?SERVER, live, 5000).

%%====================================================================
%% gen_server
%%====================================================================

init([]) ->
    process_flag(trap_exit, true),
    case root_material() of
        {error, Why} ->
            %% Acelasi principiu ca la entropie: fara radacina nu pornim.
            %% Un sistem care isi genereaza singur radacina la fiecare boot nu
            %% poate desface nimic din ce a cifrat inainte; unul care o
            %% persista langa ciphertext nu protejeaza nimic. Refuzul e
            %% singura optiune onesta.
            {stop, Why};
        {ok, Material} ->
            Root = bahmet_vault:import_root(Material, 0),
            Current = bahmet_dek_store:generation(),
            Kek = bahmet_vault:derive_generation(Root, Current),
            {ok, #state{root = Root, current = Current,
                        keks = #{Current => Kek}, retired = []}}
    end.

handle_call(generation, _From, S) ->
    {reply, S#state.current, S};

handle_call(current, _From, S) ->
    {Kek, Next} = ensure(S#state.current, S),
    {reply, {S#state.current, Kek}, Next};

handle_call({key_for, Generation}, _From, S) ->
    case lists:member(Generation, S#state.retired) of
        true ->
            {reply, {error, retired}, S};
        false ->
            {Kek, Next} = ensure(Generation, S),
            {reply, {ok, Kek}, Next}
    end;

handle_call({stage, Generation}, _From, S) ->
    {Kek, Next} = ensure(Generation, S),
    {reply, {ok, Kek}, Next#state{retired = lists:delete(Generation, Next#state.retired)}};

handle_call({promote, Generation}, _From, S) ->
    {_Kek, Next} = ensure(Generation, S),
    ok = bahmet_dek_store:set_generation(Generation),
    {reply, ok, Next#state{current = Generation}};

handle_call({retire, Generation}, _From, S = #state{current = Generation}) ->
    %% Refuzam sa retragem generatia curenta. Ar face sistemul incapabil sa
    %% deschida propriile chei noi -- o autodistrugere pe care nimeni nu o
    %% cere intentionat, deci nu o permitem din greseala.
    {reply, {error, cannot_retire_current}, S};
handle_call({retire, Generation}, _From, S) ->
    Keks = case maps:take(Generation, S#state.keks) of
               {Kek, Rest} -> _ = bahmet_vault:shred(Kek), Rest;
               error -> S#state.keks
           end,
    {reply, ok, S#state{keks = Keks,
                        retired = lists:usort([Generation | S#state.retired])}};

handle_call({issue, Aad}, _From, S) ->
    Generation = S#state.current,
    {Kek, Next} = ensure(Generation, S),
    Dek = bahmet_vault:forge_key(Generation),
    case bahmet_vault:wrap_key(Kek, Dek, Aad) of
        {ok, Wrapped} ->
            Id = bahmet_vault:fingerprint(Dek),
            ok = bahmet_dek_store:issue(Id, Generation, {Wrapped, Aad}),
            {reply, {ok, Id, Dek}, Next};
        {error, Why} ->
            _ = bahmet_vault:shred(Dek),
            {reply, {error, Why}, Next}
    end;

handle_call({open, Id}, _From, S) ->
    case bahmet_dek_store:fetch(Id) of
        {error, not_found} ->
            {reply, {error, not_found}, S};
        {ok, Generation, Wrapped, Aad} ->
            case lists:member(Generation, S#state.retired) of
                true ->
                    {reply, {error, {generation_retired, Generation}}, S};
                false ->
                    {Kek, Next} = ensure(Generation, S),
                    case bahmet_vault:unwrap_key(Kek, Wrapped, Aad, Generation) of
                        {error, Why} -> {reply, {error, Why}, Next};
                        Dek -> {reply, {ok, Dek}, Next}
                    end
            end
    end;

handle_call(live, _From, S) ->
    {reply, #{current => S#state.current,
              cached => lists:sort(maps:keys(S#state.keks)),
              retired => S#state.retired}, S};

handle_call(_Request, _From, S) ->
    {reply, {error, unknown_request}, S}.

handle_cast(_Msg, S) -> {noreply, S}.
handle_info(_Info, S) -> {noreply, S}.

terminate(_Reason, S) ->
    %% Distrugem la plecare, indiferent de motiv. Mai ales la crash.
    _ = [bahmet_vault:shred(K) || K <- maps:values(S#state.keks)],
    case S#state.root of
        redacted -> ok;
        Root -> _ = bahmet_vault:shred(Root), ok
    end.

code_change(_OldVsn, S, _Extra) -> {ok, S}.

%% Handle-urile sunt opace, dar `#Ref<>' identifica resursa in jurnale si
%% ajuta un atacator sa coreleze evenimente. Redactam din obisnuinta.
-spec format_status(gen_server:format_status()) -> gen_server:format_status().
format_status(Status = #{state := S}) ->
    Status#{state => S#state{root = redacted, keks = redacted}};
format_status(Status) ->
    Status.

%%====================================================================
%% Intern
%%====================================================================

%% Deriva la cerere si memoreaza. Derivarea e ieftina (un HKDF), dar
%% memorarea tine handle-ul viu, ceea ce conteaza pentru rotatie: nu vrem sa
%% re-derivam de o suta de mii de ori in mijlocul unei reimpachetari.
ensure(Generation, S) ->
    case maps:get(Generation, S#state.keks, undefined) of
        undefined ->
            Kek = bahmet_vault:derive_generation(S#state.root, Generation),
            {Kek, S#state{keks = maps:put(Generation, Kek, S#state.keks)}};
        Kek ->
            {Kek, S}
    end.

root_material() ->
    case os:getenv("BAHMET_ROOT_KEY") of
        false ->
            {error, {no_root_key, "seteaza BAHMET_ROOT_KEY (64 hex) dintr-un KMS extern"}};
        Hex when length(Hex) =:= 64 ->
            try
                {ok, binary:decode_hex(list_to_binary(Hex))}
            catch
                _:_ -> {error, {bad_root_key, "BAHMET_ROOT_KEY nu e hexazecimal valid"}}
            end;
        _ ->
            {error, {bad_root_key, "BAHMET_ROOT_KEY trebuie sa aiba 64 de caractere hex"}}
    end.
