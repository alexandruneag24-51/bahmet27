%%%-------------------------------------------------------------------
%%% @doc bahmet_ground — Păstrătorul temeliei.
%%%
%%% O resursă NIF trăiește atâta vreme cât un termen Erlang o ține. Acest
%%% proces există exact pentru asta: cineva trebuie să *țină* pământul, ca
%%% ceilalți să poată sta pe el.
%%%
%%% Nu calculează nimic. Nu decide nimic. Rolul lui e să dureze — și, prin
%%% faptul că e primul copil al unui arbore `rest_for_one`, propria lui
%%% durată devine garanția tuturor celorlalți.
%%% @end
%%%-------------------------------------------------------------------
-module(bahmet_ground).
-behaviour(gen_server).

-export([start_link/0, ground/0, dimension/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(DIMENSION, 256).
-define(SEED, 27).

-record(state, {ground :: bahmet_deep:ground()}).

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Împrumută temelia.
%%
%% Se întoarce un `ResourceArc` numărat prin referințe — nu o copie a celor
%% 16 MiB de ponderi. Oricâte ființe pot ține simultan aceeași temelie fără
%% niciun lacăt, tocmai fiindcă ponderile sunt imutabile după naștere.
%% Partajarea e sigură *pentru că* nimic nu se schimbă; asta e și definiția
%% unei temelii.
-spec ground() -> bahmet_deep:ground().
ground() ->
    gen_server:call(?SERVER, ground, 5000).

-spec dimension() -> pos_integer().
dimension() -> ?DIMENSION.

init([]) ->
    %% Dacă Adâncul nu poate fi deschis, eșuăm ACUM, zgomotos, la pornire.
    %% Un sistem care pornește pe jumătate și cade abia la primul calcul
    %% real e mult mai greu de înțeles decât unul care refuză din prima.
    Ground = bahmet_deep:open_ground(?DIMENSION, ?SEED),
    {ok, #state{ground = Ground}}.

handle_call(ground, _From, State) ->
    {reply, State#state.ground, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) -> {noreply, State}.
handle_info(_Info, State) -> {noreply, State}.

terminate(_Reason, _State) ->
    %% Nimic de eliberat manual. Când ultimul termen care ține resursa
    %% dispare, BEAM cheamă `Drop` în Rust. Nu există eliberare de uitat,
    %% fiindcă nu există eliberare de scris.
    ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.
