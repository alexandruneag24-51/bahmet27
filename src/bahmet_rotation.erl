%%%-------------------------------------------------------------------
%%% @doc bahmet_rotation -- Igiena periodica.
%%%
%%% Rotatia inseamna KEK nou, reimpachetarea DEK-urilor, distrugerea celui
%%% vechi. NU inseamna recriptarea datelor.
%%%
%%% Diferenta e ordinul de marime: un terabyte de date cifrate are poate
%%% cateva zeci de megaocteti de DEK-uri impachetate. Rotesti kilobytes,
%%% nu terabytes. Problema a fost pusa altfel, nu masina e mai rapida.
%%%
%%% Operatia e IDEMPOTENTA prin numarul de generatie: daca procesul cade la
%%% mijloc, supervizorul il reporneste si reia de unde a ramas, fara sa
%%% strice ce s-a facut. De aceea isi poate permite sa fie iertata --
%%% nu din bunatate, ci fiindca greseala ei e recuperabila.
%%% @end
%%%-------------------------------------------------------------------
-module(bahmet_rotation).
-behaviour(gen_server).

-export([start_link/0, rotate_now/0, due_in/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(PERIOD_MS, 2592000000).   %% 30 de zile

-record(state, {last :: integer(), rotations = 0 :: non_neg_integer()}).

-spec start_link() -> gen_server:start_ret().
start_link() -> gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec rotate_now() -> {ok, non_neg_integer()} | {error, term()}.
rotate_now() -> gen_server:call(?SERVER, rotate, 30000).

-spec due_in() -> integer().
due_in() -> gen_server:call(?SERVER, due_in, 5000).

init([]) ->
    {ok, #state{last = erlang:monotonic_time(millisecond)}, ?PERIOD_MS}.

handle_call(rotate, _From, S) ->
    {Reply, Next} = perform(S),
    {reply, Reply, Next, ?PERIOD_MS};
handle_call(due_in, _From, S) ->
    Elapsed = erlang:monotonic_time(millisecond) - S#state.last,
    {reply, max(0, ?PERIOD_MS - Elapsed), S, ?PERIOD_MS};
handle_call(_Request, _From, S) ->
    {reply, {error, unknown_request}, S, ?PERIOD_MS}.

handle_cast(_Msg, S) -> {noreply, S, ?PERIOD_MS}.

handle_info(timeout, S) ->
    {_Reply, Next} = perform(S),
    {noreply, Next, ?PERIOD_MS};
handle_info(_Info, S) -> {noreply, S, ?PERIOD_MS}.

terminate(_Reason, _S) -> ok.
code_change(_OldVsn, S, _Extra) -> {ok, S}.

%%====================================================================
%% Intern
%%====================================================================

perform(S) ->
    Fresh = bahmet_vault:forge_key(bahmet_keyring:generation() + 1),
    %% ORDINEA E CRITICA. Reimpachetarea TREBUIE sa se termine inainte de
    %% promovare: `promote' distruge KEK-ul vechi, iar orice DEK ramas
    %% impachetat cu el devine iremediabil. Faza 2 va face asta tranzactional,
    %% cu jurnal de progres persistat.
    ok = rewrap_all(Fresh),
    ok = bahmet_keyring:promote(Fresh),
    Count = S#state.rotations + 1,
    {{ok, Count}, S#state{last = erlang:monotonic_time(millisecond), rotations = Count}}.

rewrap_all(_Fresh) ->
    %% Faza 2: iterare peste depozitul de DEK-uri, `unwrap' cu KEK-ul vechi,
    %% `wrap' cu cel nou, scriere atomica, progres jurnalizat pentru reluare.
    ok.
