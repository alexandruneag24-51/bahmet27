%%%-------------------------------------------------------------------
%%% @doc bahmet_sentinel -- Intuitia Apei Yin, aplicata la ceva masurabil.
%%%
%%% ═══════════════════════════════════════════════════════════════════
%%%  CE VEDE SI CE NU VEDE
%%% ═══════════════════════════════════════════════════════════════════
%%%
%%%   Vede: rate de cerere, rapoarte esec/succes, intervale intre cereri,
%%%         varsta cheii la acces, amprente publice de 8 octeti.
%%%
%%%   Nu vede: plaintext, material de cheie, continutul AAD, identitatea
%%%            obiectelor.
%%%
%%% Proprietatea e STRUCTURALA, nu politica. Acest proces nu primeste
%%% niciodata un handle si nu apeleaza nicio functie care intoarce
%%% plaintext. Nu „nu are voie" -- nu poate.
%%%
%%% ═══════════════════════════════════════════════════════════════════
%%%  RAPORTEAZA. NU EXECUTA.
%%% ═══════════════════════════════════════════════════════════════════
%%%
%%% Un detector care poate revoca chei singur este un vector de auto-DoS:
%%% un atacator declanseaza intentionat alarme si iti opreste sistemul.
%%% Actiunile distructive cer confirmare umana. Santinela ridica un semnal
%%% si atat -- iar faptul ca e `transient' si ultima in arbore inseamna ca,
%%% daca se impiedica, seiful merge mai departe orb, dar viu.
%%% @end
%%%-------------------------------------------------------------------
-module(bahmet_sentinel).
-behaviour(gen_server).

-export([start_link/0, observe/3, concerns/0, posture/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(WINDOW, 256).
-define(ALARM_THRESHOLD, 0.85).

-record(state, {
    window   = []        :: [{integer(), atom(), non_neg_integer()}],
    posture  = undefined :: [float()] | undefined,
    concerns = []        :: [map()]
}).

-spec start_link() -> gen_server:start_ret().
start_link() -> gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc `mobilize sentinel.observe(...)' -- cast, deliberat.
%% Observatorul nu are voie sa incetineasca pe cel observat. Un santinel
%% sincron ar deveni o limita de debit pentru intreg seiful.
-spec observe(Realm :: atom(), Operations :: non_neg_integer(),
              Outcome :: ok | denied) -> ok.
observe(Realm, Operations, Outcome) ->
    gen_server:cast(?SERVER, {observe, Realm, Operations, Outcome,
                              erlang:monotonic_time(millisecond)}).

-spec concerns() -> [map()].
concerns() -> gen_server:call(?SERVER, concerns, 5000).

-spec posture() -> [float()] | undefined.
posture() -> gen_server:call(?SERVER, posture, 5000).

init([]) -> {ok, #state{}}.

handle_call(concerns, _From, S) -> {reply, lists:reverse(S#state.concerns), S};
handle_call(posture, _From, S)  -> {reply, S#state.posture, S};
handle_call(_Request, _From, S) -> {reply, {error, unknown_request}, S}.

handle_cast({observe, Realm, Ops, Outcome, At}, S) ->
    Window = lists:sublist([{At, Outcome, Ops} | S#state.window], ?WINDOW),
    Next = S#state{window = Window},
    {noreply, appraise(Realm, Next)};
handle_cast(_Msg, S) -> {noreply, S}.

handle_info(_Info, S) -> {noreply, S}.
terminate(_Reason, _S) -> ok.
code_change(_OldVsn, S, _Extra) -> {ok, S}.

%%====================================================================
%% Intern
%%====================================================================

%% Nu judecam pe date putine. Un model care se pronunta dupa trei observatii
%% produce alarme false, iar alarmele false antreneaza oamenii sa le ignore --
%% ceea ce e mai rau decat sa nu ai deloc detector.
appraise(_Realm, S) when length(S#state.window) < 32 -> S;
appraise(Realm, S) ->
    Features = shape(S#state.window),
    case bahmet_deep:intuit(bahmet_ground:ground(), Features) of
        {ok, Distribution} ->
            Report = bahmet_deep:reflect(bahmet_ground:ground()),
            Certainty = maps:get(coherence, Report, 0.0),
            weigh(Realm, Distribution, Certainty, S);
        _ ->
            S
    end.

weigh(Realm, _Distribution, Certainty, S) when Certainty > ?ALARM_THRESHOLD ->
    Concern = #{realm => Realm,
                certainty => Certainty,
                at => erlang:system_time(second),
                action => report_only},
    logger:warning("bahmet_sentinel: tipar neobisnuit in ~p (certitudine ~.3f)",
                   [Realm, Certainty]),
    S#state{concerns = [Concern | S#state.concerns]};
weigh(_Realm, _Distribution, _Certainty, S) ->
    %% `withhold judgement' -- sub prag, tacem. Un model care isi raporteaza
    %% indoiala e mai util decat unul care pare mereu sigur.
    S.

%% Vectorul de trasaturi. Doar forme: rate, rapoarte, intervale.
%% Niciun octet de continut nu ajunge aici, prin constructie.
shape(Window) ->
    Total = length(Window),
    Denied = length([x || {_, denied, _} <- Window]),
    Times = [T || {T, _, _} <- Window],
    Spread = case Times of
                 [H | _] -> abs(H - lists:last(Times)) / 1000.0;
                 [] -> 0.0
             end,
    Base = [Denied / max(1, Total),
            Total / ?WINDOW,
            min(1.0, Spread / 60.0)],
    %% bahmet_deep asteapta dimensiunea temeliei; completam cu zerouri.
    Dim = bahmet_ground:dimension(),
    Base ++ lists:duplicate(max(0, Dim - length(Base)), 0.0).
