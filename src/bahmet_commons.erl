%%%-------------------------------------------------------------------
%%% @doc bahmet_commons — Bunul comun.
%%%
%%% Aici se varsă împlinirile. E important ce NU este acest modul:
%%%
%%%   • nu e o tabelă ETS scriabilă din exterior
%%%   • nu e o variabilă globală
%%%   • nu e memorie partajată sub nicio formă
%%%
%%% Este o ființă ca oricare alta, care primește daruri prin mesaje. Nimeni
%%% nu *scrie* în bunul comun; toți îi *oferă*. Diferența pare semantică, dar
%%% e structurală: din ea decurge că nu există curse, nu există lacăte, și nu
%%% există nicio clipă în care înțelepciunea comună să fie pe jumătate scrisă.
%%% @end
%%%-------------------------------------------------------------------
-module(bahmet_commons).
-behaviour(gen_server).

-export([start_link/0, merge/2, wisdom/0, contributors/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {
    offerings = []    :: [bahmet_deep:tensor()],
    givers    = []    :: [term()],
    received  = 0     :: non_neg_integer()
}).

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc `completion merging Insight into wisdom`.
%%
%% `cast`, deliberat. Cel care dăruiește este, prin definiție, pe cale să
%% plece: nu are voie să fie ținut în loc de starea bunului comun. Un dar
%% care blochează pe cel ce-l face nu e chiar un dar.
-spec merge(Giver :: term(), bahmet_deep:tensor()) -> ok.
merge(Giver, Tensor) when is_list(Tensor) ->
    gen_server:cast(?SERVER, {merge, Giver, Tensor}).

%% @doc Înțelepciunea de până acum: centroidul tuturor ofrandelor.
-spec wisdom() -> {ok, bahmet_deep:tensor()} | {error, no_offerings}.
wisdom() ->
    gen_server:call(?SERVER, wisdom, 5000).

-spec contributors() -> [term()].
contributors() ->
    gen_server:call(?SERVER, contributors, 5000).

init([]) ->
    {ok, #state{}}.

handle_call(wisdom, _From, State = #state{offerings = []}) ->
    %% Un cerc care n-a primit încă nimic spune asta cinstit, în loc să
    %% întoarcă un tensor de zerouri care ar arăta ca un răspuns.
    {reply, {error, no_offerings}, State};
handle_call(wisdom, _From, State = #state{offerings = Offerings}) ->
    %% Contopirea se face în Rust: media, apoi renormalizarea pe simplex.
    %% Nicio ofrandă nu cântărește mai mult decât alta, indiferent cine a
    %% dat-o sau când. Egalitatea e o proprietate a funcției, nu o politică.
    {reply, bahmet_deep:commune(Offerings), State};

handle_call(contributors, _From, State) ->
    {reply, lists:reverse(State#state.givers), State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast({merge, Giver, Tensor}, State) ->
    %% Adăugăm în față: O(1). Ordinea internă nu contează, fiindcă operația
    %% finală (centroidul) e comutativă. Când structura de date se potrivește
    %% cu matematica, nu mai e nevoie nici de sortare, nici de disciplină.
    {noreply, State#state{
        offerings = [Tensor | State#state.offerings],
        givers    = [Giver | State#state.givers],
        received  = State#state.received + 1
    }};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.
