%%%-------------------------------------------------------------------
%%% @doc bahmet_dek_store -- Catalogul cheilor de date.
%%%
%%% Nu poti roti ce nu poti enumera. Pana acum, DEK-urile existau doar ca
%%% handle-uri efemere: se nasteau, cifrau ceva, si dispareau odata cu
%%% procesul care le tinea. `rewrap_all' nu avea peste ce sa itereze.
%%%
%%% Depozitul tine, pentru fiecare DEK: identitatea, generatia KEK-ului cu
%%% care e impachetat, si octetii impachetati. NU tine cheia -- aceea
%%% traieste doar in Rust, iar aici sta doar forma ei sigilata.
%%%
%%% ═══════════════════════════════════════════════════════════════════
%%%  DE CE `generation' STA IN FIECARE INREGISTRARE
%%% ═══════════════════════════════════════════════════════════════════
%%%
%%% Fiindca asta face rotatia idempotenta si reluabila. Un DEK deja ajuns la
%%% generatia tinta pur si simplu nu mai apare in `pending/2'. O cadere la
%%% mijlocul rotatiei lasa in urma un amestec de generatii -- perfect valid,
%%% fiecare DEK deschizandu-se cu cheia lui. Reluarea nu are nevoie de niciun
%%% jurnal de progres: intreaba din nou cine a ramas.
%%%
%%% Starea de progres nu se memoreaza, se recalculeaza. Ce nu memorezi nu se
%%% poate desincroniza.
%%%
%%% NOTA DE ONESTITATE: DETS e ales pentru ca e in OTP si nu adauga dependinte.
%%% Are limita de 2 GB si un istoric de corupere la opriri necurate. Pentru
%%% productie, vezi CRYPTO.md -- un depozit real sau un log append-only.
%%% @end
%%%-------------------------------------------------------------------
-module(bahmet_dek_store).
-behaviour(gen_server).

-export([start_link/0,
         issue/3, fetch/1, commit/3, forget/1,
         pending/2, count/0, tally/0,
         generation/0, set_generation/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(TABLE, bahmet_deks).

%% `id' e cheia (element 2). Meta-inregistrarile folosesc alt tag de tuplu,
%% deci nu se potrivesc niciodata cu tiparele `#dek{}' din `pending/2'.
-record(dek, {
    id         :: binary(),
    generation :: non_neg_integer(),
    wrapped    :: binary(),
    aad        :: binary(),
    created    :: integer()
}).

-record(state, {table :: dets:tab_name()}).

%%====================================================================
%% API
%%====================================================================

-spec start_link() -> gen_server:start_ret().
start_link() -> gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Inregistreaza un DEK nou impachetat.
-spec issue(Id :: binary(), Generation :: non_neg_integer(),
            {Wrapped :: binary(), Aad :: binary()}) -> ok.
issue(Id, Generation, {Wrapped, Aad}) ->
    gen_server:call(?SERVER, {issue, Id, Generation, Wrapped, Aad}, 10000).

-spec fetch(Id :: binary()) ->
          {ok, non_neg_integer(), binary(), binary()} | {error, not_found}.
fetch(Id) -> gen_server:call(?SERVER, {fetch, Id}, 10000).

%% @doc Muta un DEK la o generatie noua. Atomic per inregistrare.
%%
%% Aici e granularitatea sigurantei: o cadere intre doua confirmari lasa
%% depozitul consistent, nu pe jumatate scris.
-spec commit(Id :: binary(), Generation :: non_neg_integer(),
             Wrapped :: binary()) -> ok | {error, not_found}.
commit(Id, Generation, Wrapped) ->
    gen_server:call(?SERVER, {commit, Id, Generation, Wrapped}, 10000).

%% @doc Sterge inregistrarea. Datele cifrate cu acel DEK devin zgomot.
-spec forget(Id :: binary()) -> ok.
forget(Id) -> gen_server:call(?SERVER, {forget, Id}, 10000).

%% @doc Cine NU e inca la generatia tinta. Cel mult `Limit' deodata.
%%
%% Continuarea `dets:select/3' e aruncata DELIBERAT. Dupa fiecare confirmare,
%% randurile rescrise ies singure din filtru, deci urmatoarea interogare
%% intoarce natural urmatorul lot. O continuare pastrata ar fi stare care
%% supravietuieste unei caderi si ar minti dupa ea.
-spec pending(Target :: non_neg_integer(), Limit :: pos_integer()) ->
          [{binary(), non_neg_integer(), binary(), binary()}].
pending(Target, Limit) ->
    gen_server:call(?SERVER, {pending, Target, Limit}, 30000).

-spec count() -> non_neg_integer().
count() -> gen_server:call(?SERVER, count, 10000).

%% @doc Cate DEK-uri pe fiecare generatie. Pentru audit si observator.
-spec tally() -> #{non_neg_integer() => non_neg_integer()}.
tally() -> gen_server:call(?SERVER, tally, 30000).

%% @doc Generatia curenta, persistata. Keyring-ul o citeste la pornire.
-spec generation() -> non_neg_integer().
generation() -> gen_server:call(?SERVER, generation, 10000).

-spec set_generation(non_neg_integer()) -> ok.
set_generation(Generation) ->
    gen_server:call(?SERVER, {set_generation, Generation}, 10000).

%%====================================================================
%% gen_server
%%====================================================================

init([]) ->
    process_flag(trap_exit, true),
    Path = path(),
    ok = filelib:ensure_dir(Path),
    {ok, Table} = dets:open_file(?TABLE, [{file, Path},
                                          {type, set},
                                          {keypos, #dek.id},
                                          {auto_save, 1000}]),
    {ok, #state{table = Table}}.

handle_call({issue, Id, Generation, Wrapped, Aad}, _From, S) ->
    Record = #dek{id = Id, generation = Generation, wrapped = Wrapped,
                  aad = Aad, created = erlang:system_time(second)},
    {reply, write(S#state.table, Record), S};

handle_call({fetch, Id}, _From, S) ->
    Reply = case dets:lookup(S#state.table, Id) of
                [#dek{generation = G, wrapped = W, aad = A}] -> {ok, G, W, A};
                [] -> {error, not_found}
            end,
    {reply, Reply, S};

handle_call({commit, Id, Generation, Wrapped}, _From, S) ->
    Reply = case dets:lookup(S#state.table, Id) of
                [Record] ->
                    write(S#state.table,
                          Record#dek{generation = Generation, wrapped = Wrapped});
                [] ->
                    {error, not_found}
            end,
    {reply, Reply, S};

handle_call({forget, Id}, _From, S) ->
    ok = dets:delete(S#state.table, Id),
    ok = dets:sync(S#state.table),
    {reply, ok, S};

handle_call({pending, Target, Limit}, _From, S) ->
    Spec = [{#dek{generation = '$1', _ = '_'}, [{'=/=', '$1', Target}], ['$_']}],
    Reply = case dets:select(S#state.table, Spec, Limit) of
                {Records, _Continuation} -> [flatten(R) || R <- Records];
                '$end_of_table' -> []
            end,
    {reply, Reply, S};

handle_call(count, _From, S) ->
    Spec = [{#dek{_ = '_'}, [], [true]}],
    {reply, length(dets:select(S#state.table, Spec)), S};

handle_call(tally, _From, S) ->
    Spec = [{#dek{generation = '$1', _ = '_'}, [], ['$1']}],
    Counted = lists:foldl(fun(G, Acc) -> maps:update_with(G, fun(N) -> N + 1 end, 1, Acc) end,
                          #{}, dets:select(S#state.table, Spec)),
    {reply, Counted, S};

handle_call(generation, _From, S) ->
    Reply = case dets:lookup(S#state.table, current_generation) of
                [{meta, current_generation, G}] -> G;
                [] -> 0
            end,
    {reply, Reply, S};

handle_call({set_generation, Generation}, _From, S) ->
    ok = dets:insert(S#state.table, {meta, current_generation, Generation}),
    ok = dets:sync(S#state.table),
    {reply, ok, S};

handle_call(_Request, _From, S) ->
    {reply, {error, unknown_request}, S}.

handle_cast(_Msg, S) -> {noreply, S}.
handle_info(_Info, S) -> {noreply, S}.

terminate(_Reason, S) ->
    _ = dets:sync(S#state.table),
    _ = dets:close(S#state.table),
    ok.

code_change(_OldVsn, S, _Extra) -> {ok, S}.

%%====================================================================
%% Intern
%%====================================================================

%% `sync' dupa fiecare scriere. Lent, si intentionat asa: o confirmare
%% pierduta inseamna un DEK pe care cheia noua nu-l poate deschide, dupa ce
%% cea veche a fost deja retrasa. Durabilitatea bate debitul aici.
write(Table, Record) ->
    ok = dets:insert(Table, Record),
    ok = dets:sync(Table),
    ok.

flatten(#dek{id = Id, generation = G, wrapped = W, aad = A}) -> {Id, G, W, A}.

path() ->
    application:get_env(bahmet, dek_store_file, "bahmet_deks.dets").
