%%%-------------------------------------------------------------------
%%% @doc bahmet_council_sup — Adunarea.
%%%
%%% Aici se nasc ființele și tot aici se împlinesc.
%%%
%%% ═══════════════════════════════════════════════════════════════════
%%%  DE CE `one_for_one` AICI, DAR `rest_for_one` LA RĂDĂCINĂ
%%% ═══════════════════════════════════════════════════════════════════
%%%
%%% Între contemplatori nu există nicio dependență. Fiecare are propria
%%% întrebare, propria stare, propria cutie poștală. Căderea unuia nu spune
%%% absolut nimic despre sănătatea celorlalți.
%%%
%%% `one_for_one` codifică exact această independență: fiecare ființă e
%%% singură în fața propriei greșeli, dar niciodată singură în cerc. A folosi
%%% `one_for_all` aici ar fi o cruzime *și* o eroare tehnică — ar șterge munca
%%% a nouă ființe sănătoase pentru greșeala uneia. Corectitudinea tehnică și
%%% cea morală indică aceeași strategie; nu e o coincidență, e semnul că
%%% maparea e reală, nu decorativă.
%%%
%%% ═══════════════════════════════════════════════════════════════════
%%%  ÎMPLINIREA CA MECANISM (OTP 24+)
%%% ═══════════════════════════════════════════════════════════════════
%%%
%%% Trei chei lucrează împreună ca „completarea" să fie structurală, nu o
%%% convenție pe care codul o poate uita:
%%%
%%%   restart => transient      — terminarea normală nu se repornește
%%%   significant => true       — plecarea acestui copil contează pentru întreg
%%%   auto_shutdown => all_significant  — când toți s-au împlinit, se împlinește
%%%                                        și adunarea, și se stinge cu grație
%%%
%%% Rezultatul: întregul își recunoaște propria împlinire *prin* împlinirea
%%% părților, fără ca cineva să numere, să sondeze sau să dea un semnal.
%%% Nu există „coordonator" — există doar structură.
%%%
%%% (`significant` este permis doar cu `transient` sau `temporary`, exact
%%% fiindcă un copil `permanent` nu poate pleca definitiv nicicum.)
%%% @end
%%%-------------------------------------------------------------------
-module(bahmet_council_sup).
-behaviour(supervisor).

-export([start_link/0, birth/1, present/0, await_completion/1]).
-export([init/1]).

-define(SERVER, ?MODULE).

%% Răgazul de dăruire: câtă vreme are o ființă, la oprire, ca să-și verse
%% înțelegerea în bunul comun. Vezi bahmet_contemplator:terminate/2.
-define(GRACE, 5000).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

-spec init([]) -> {ok, {supervisor:sup_flags(), []}}.
init([]) ->
    SupFlags = #{
        strategy      => one_for_one,
        intensity     => 5,
        period        => 60,
        auto_shutdown => all_significant
    },
    %% Pornim goi. Un cerc nu se naște plin — el se adună.
    %% (Un supervizor fără copii nu declanșează auto_shutdown; oprirea
    %% automată se evaluează la *terminarea* unui copil semnificativ.)
    {ok, {SupFlags, []}}.

%%====================================================================
%% API
%%====================================================================

%% @doc `birth Contemplator into Gathering with (Question)`.
-spec birth(Question :: binary()) -> {ok, pid()} | {error, term()}.
birth(Question) when is_binary(Question) ->
    %% Identitatea copilului este un întreg unic, NU un atom.
    %%
    %% Motivul e sever și practic: tabela de atomi a mașinii virtuale nu se
    %% colectează niciodată. Un sistem care naște liber și își numește copiii
    %% cu atomi generați dinamic își sapă groapa lent, apoi moare brusc și
    %% inexplicabil, luni mai târziu. Libertatea de a naște obligă la
    %% disciplina de a nu consuma o resursă care nu se întoarce.
    Id = {contemplator, erlang:unique_integer([positive, monotonic])},

    ChildSpec = #{
        id       => Id,
        start    => {bahmet_contemplator, start_link, [Id, Question]},

        %% Împlinirea nu e eșec. Vezi antetul modulului.
        restart  => transient,

        %% Plecarea acestei ființe contează pentru soarta întregului.
        significant => true,

        %% Timp de dăruit înainte de a se stinge.
        shutdown => ?GRACE,

        type     => worker,
        modules  => [bahmet_contemplator]
    },

    supervisor:start_child(?SERVER, ChildSpec).

%% @doc Cine este viu acum în adunare.
%%
%% Un copil `transient` care s-a împlinit rămâne în listă cu pid-ul
%% `undefined`: supervizorul își amintește că a existat, dar nu îl reînvie.
%% Filtrăm — răspundem la „cine e prezent", nu la „cine a fost vreodată".
-spec present() -> [pid()].
present() ->
    [Pid || {_Id, Pid, _Type, _Mods} <- supervisor:which_children(?SERVER),
            is_pid(Pid)].

%% @doc `await Gathering completion within Timeout`.
%%
%% Așteptăm prin monitorizare, nu prin sondare într-o buclă. A întreba
%% repetat „ai terminat?" e nerăbdare deghizată în cod; un monitor este
%% așteptare adevărată — costă zero până în clipa în care chiar se întâmplă
%% ceva. Răbdarea, aici, e literalmente mai ieftină decât graba.
-spec await_completion(timeout()) -> complete | {timeout, pid()} | not_gathered.
await_completion(Timeout) ->
    case whereis(?SERVER) of
        undefined ->
            not_gathered;
        Pid ->
            Ref = erlang:monitor(process, Pid),
            receive
                {'DOWN', Ref, process, Pid, _Reason} ->
                    complete
            after Timeout ->
                %% Demontăm monitorul și golim cutia poștală de un eventual
                %% 'DOWN' sosit chiar în cursa dintre `after` și `demonitor`.
                %% Un proces care nu-și curăță urmele lasă gunoi altora.
                erlang:demonitor(Ref, [flush]),
                {timeout, Pid}
            end
    end.
