%%%-------------------------------------------------------------------
%%% @doc bahmet_entropy -- Temelia care nu se negociaza.
%%%
%%% Singurul modul din sistem care are dreptul sa refuze pornirea.
%%%
%%% Motivul e simplu si dur: o cheie generata din entropie proasta arata
%%% identic cu una buna. Nu exista test la rulare care sa le distinga.
%%% Daca sursa e rupta, sistemul va parea ca functioneaza perfect, va cifra
%%% cu succes, va desface cu succes -- si va fi complet transparent pentru
%%% oricine stie sa se uite.
%%%
%%% De aceea aici nu exista degradare eleganta. Fie sursa raspunde, fie nu
%%% pornim. E singura forma de generozitate disponibila: sa nu lasi pe
%%% nimeni sa creada ca e protejat cand nu e.
%%% @end
%%%-------------------------------------------------------------------
-module(bahmet_entropy).
-behaviour(gen_server).

-export([start_link/0, healthy/0, recheck/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
%% Reverificam periodic. O sursa poate degrada in timp -- containere clonate,
%% masini virtuale restaurate din snapshot, medii embedded la boot rece.
-define(RECHECK_MS, 300000).

-record(state, {healthy :: boolean(), checks = 0 :: non_neg_integer()}).

-spec start_link() -> gen_server:start_ret().
start_link() -> gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec healthy() -> boolean().
healthy() -> gen_server:call(?SERVER, healthy, 5000).

-spec recheck() -> boolean().
recheck() -> gen_server:call(?SERVER, recheck, 5000).

init([]) ->
    case bahmet_vault:entropy_health() of
        {ok, true} ->
            {ok, #state{healthy = true, checks = 1}, ?RECHECK_MS};
        {ok, false} ->
            %% Oprim TOT. Fiind primul copil al unui arbore rest_for_one,
            %% refuzul de aici opreste intreaga pornire a seifului.
            {stop, {entropy_degraded, "sursa CSPRNG nu produce iesire valida"}}
    end.

handle_call(healthy, _From, State) ->
    {reply, State#state.healthy, State, ?RECHECK_MS};
handle_call(recheck, _From, State) ->
    {ok, Healthy} = bahmet_vault:entropy_health(),
    Next = State#state{healthy = Healthy, checks = State#state.checks + 1},
    case Healthy of
        true  -> {reply, true, Next, ?RECHECK_MS};
        %% Degradare in timpul functionarii: murim, iar rest_for_one
        %% refondeaza tot ce s-a construit peste noi.
        false -> {stop, entropy_degraded, false, Next}
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State, ?RECHECK_MS}.

handle_cast(_Msg, State) -> {noreply, State, ?RECHECK_MS}.

handle_info(timeout, State) ->
    {ok, Healthy} = bahmet_vault:entropy_health(),
    Next = State#state{healthy = Healthy, checks = State#state.checks + 1},
    case Healthy of
        true  -> {noreply, Next, ?RECHECK_MS};
        false -> {stop, entropy_degraded, Next}
    end;
handle_info(_Info, State) -> {noreply, State, ?RECHECK_MS}.

terminate(_Reason, _State) -> ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.
