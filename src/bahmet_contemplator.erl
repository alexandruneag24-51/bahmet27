%%%-------------------------------------------------------------------
%%% @doc bahmet_contemplator — Ființa.
%%%
%%% Un actor. Nu împarte memorie cu nimeni, nu ia niciun lacăt, nu se ia la
%%% întrecere pentru nicio resursă. Tot ce are stă în `#state{}` și piere
%%% odată cu el — dacă nu alege să dăruiască.
%%%
%%% Nu există nicio funcție în acest modul prin care o altă ființă să poată
%%% citi sau scrie starea acesteia. Nu e o convenție de politețe: pur și
%%% simplu nu există sintaxă pentru asta. Parteneriatul nu e impus prin
%%% reguli de echipă, ci prin absența alternativei.
%%% @end
%%%-------------------------------------------------------------------
-module(bahmet_contemplator).
-behaviour(gen_server).

-export([start_link/2, offer/2, call_home/1, reflection/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3, format_status/1]).

%% RĂBDAREA. Declarată, mărginită, vizibilă.
%% O ființă care ar aștepta la nesfârșit nu e răbdătoare — e blocată, și
%% ocupă un loc pe care altcineva l-ar folosi. Răbdarea adevărată știe când
%% să se retragă.
%%
%% Citită o singură dată, la naștere, și păstrată în stare. Două motive:
%% o ființă vie își păstrează răbdarea cu care s-a născut chiar dacă se
%% schimbă configurația sub ea, iar suita de teste poate coborî valoarea la
%% 300ms ca să observe retragerea. Un invariant care nu poate fi testat în
%% mai puțin de o jumătate de minut, în practică, nu e testat niciodată.
-define(DEFAULT_PATIENCE, 30000).

-record(state, {
    id        :: term(),
    question  :: binary(),
    ground    :: bahmet_deep:ground(),
    insight   :: bahmet_deep:tensor() | undefined | redacted,
    offerings = 0 :: non_neg_integer(),
    patience  :: timeout()
}).

%%====================================================================
%% API
%%====================================================================

-spec start_link(Id :: term(), Question :: binary()) -> gen_server:start_ret().
start_link(Id, Question) ->
    %% Neînregistrat: ființa e cunoscută prin pid, nu prin nume global.
    %% Un nume global e o formă de memorie partajată; îl evităm.
    gen_server:start_link(?MODULE, {Id, Question}, []).

%% @doc `offer offering(Seed) to One` — un dar. Asincron prin definiție:
%% cel care dăruiește nu se blochează așteptând mulțumiri.
-spec offer(pid(), bahmet_deep:tensor()) -> ok.
offer(Who, Seed) when is_list(Seed) ->
    gen_server:cast(Who, {offering, Seed, self()}).

%% @doc `offer calling_home to One` — invitația la împlinire.
%% Tot un cast: nici chemarea acasă nu e un ordin care blochează.
-spec call_home(pid()) -> ok.
call_home(Who) ->
    gen_server:cast(Who, calling_home).

%% @doc `ask reflection within 1s` — singura formă sincronă, cu limită.
-spec reflection(pid()) -> map().
reflection(Who) ->
    gen_server:call(Who, reflection, 1000).

%%====================================================================
%% gen_server
%%====================================================================

init({Id, Question}) ->
    %% `trap_exit` ca `terminate/2` să fie chemat la oprirea dinspre
    %% supervizor. Fără el, ființa ar fi ucisă fără să apuce să dăruiască:
    %% răgazul acordat de supervizor (`shutdown => 5000`) ar rămâne un gest
    %% gol. Grija cuiva față de tine trebuie și primită, nu doar oferită.
    process_flag(trap_exit, true),

    %% Cerem temelia. Dacă bahmet_ground nu e viu, acest apel se declanșează,
    %% `init` eșuează, iar supervizorul află imediat. Nu inventăm o temelie
    %% de rezervă: o intuiție construită pe un pământ improvizat e mai rea
    %% decât nicio intuiție.
    Ground = bahmet_ground:ground(),

    Patience = application:get_env(bahmet, patience, ?DEFAULT_PATIENCE),
    State = #state{id = Id, question = Question, ground = Ground,
                   patience = Patience},

    %% Al treilea element = răbdarea. De aici încolo, tăcerea are termen.
    {ok, State, Patience}.

%% ── PRIMIRE ──────────────────────────────────────────────────────────
handle_cast({offering, Seed, Giver}, State = #state{ground = Ground}) ->
    %% Traversarea punții. Rulează pe planificator murdar în Rust, deci acest
    %% proces se blochează — dar NUMAI acest proces. Celelalte ființe de pe
    %% același fir continuă neatinse. Asta e diferența dintre a fi ocupat
    %% și a fi lacom.
    {ok, Fresh} = bahmet_deep:intuit(Ground, Seed),

    %% Înțelegerea nouă nu o înlocuiește pe cea veche: se contopește cu ea.
    %% Ce a fost învățat înainte nu se aruncă fiindcă a sosit ceva mai nou.
    Blended = blend(State#state.insight, Fresh),

    %% Mulțumim, fără să cerem confirmare pentru mulțumire.
    gen_server:cast(Giver, {thanks, self(), State#state.offerings + 1}),

    {noreply,
     State#state{insight = Blended, offerings = State#state.offerings + 1},
     State#state.patience};

%% ── ÎMPLINIREA ───────────────────────────────────────────────────────
handle_cast(calling_home, State) ->
    %% `normal`. Nu `shutdown`, nu `{error, done}`. Cuvântul contează:
    %% supervizorul e `transient`, deci `normal` înseamnă „a reușit, lăsați-o
    %% în pace". Ființa nu moare — termină.
    %%
    %% Dăruirea propriu-zisă se face în `terminate/2`, adică pe *toate*
    %% drumurile de ieșire, nu doar pe acesta. Altruismul scris o singură
    %% dată, într-un loc prin care se trece obligatoriu.
    {stop, normal, State};

handle_cast(_Ignored, State) ->
    %% Un mesaj de neînțeles nu e un motiv de moarte. Îl lăsăm să treacă și
    %% ne reînnoim răbdarea.
    {noreply, State, State#state.patience}.

%% ── INTROSPECȚIE ─────────────────────────────────────────────────────
handle_call(reflection, _From, State = #state{ground = Ground}) ->
    Report = bahmet_deep:reflect(Ground),
    Answer = Report#{
        question  => State#state.question,
        offerings => State#state.offerings,
        settled   => State#state.insight =/= undefined
    },
    {reply, Answer, State, State#state.patience};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State, State#state.patience}.

%% ── TĂCEREA ──────────────────────────────────────────────────────────
handle_info(timeout, State) ->
    %% Răbdarea s-a epuizat. Ființa nu se plânge și nu cere prelungire:
    %% eliberează locul.
    %%
    %% `{shutdown, silence}` — pentru un copil `transient`, tuplul
    %% `{shutdown, _}` NU este considerat terminare anormală, deci nu declanșează
    %% repornire. Ne retragem *și* rămânem catalogați drept împliniți; nu ne
    %% transformăm retragerea în alarmă pentru tot cercul.
    {stop, {shutdown, silence}, State};

handle_info({'EXIT', _Pid, Reason}, State) ->
    {stop, Reason, State};

handle_info(_Info, State) ->
    {noreply, State, State#state.patience}.

%% ── PLECAREA ─────────────────────────────────────────────────────────
%%
%% Trei feluri de a pleca, trei purtări diferite. Ordinea clauzelor este
%% ea însăși o afirmație morală.

%% 1. ÎMPLINIRE — drumul dus până la capăt. Dăruiește.
terminate(normal, State) ->
    offer_up(State);

%% 2. RETRAGERE ALTRUISTĂ — i s-a cerut să plece, sau tăcerea a fost prea
%%    lungă. Dăruiește oricum ce a apucat să adune. Nu-și ia cu sine ce ar
%%    putea folosi celorlalți, doar fiindcă plecarea nu a fost alegerea ei.
terminate(shutdown, State) ->
    offer_up(State);
terminate({shutdown, _Why}, State) ->
    offer_up(State);

%% 3. RUPTURĂ — ceva s-a frânt înăuntru. NU dăruiește.
%%
%%    Aceasta e clauza cea mai importantă din modul. O stare pe jumătate
%%    scrisă, vărsată în bunul comun, otrăvește fiecare intuiție viitoare a
%%    fiecărei ființe — tăcut, și pentru totdeauna. Altruismul fără integritate
%%    nu e generozitate, e contaminare.
%%
%%    A da nimic este, aici, actul cel mai altruist disponibil.
terminate(_Broken, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ── A DOUA IEȘIRE ────────────────────────────────────────────────────
%%
%% Clauza `terminate(_Broken, _)` refuză să verse o stare ruptă în bunul
%% comun. Dar starea are mai multe ieșiri decât cea intenționată: la
%% prăbușire, error loggerul OTP tipărește `#state{}` integral în jurnal —
%% adică exact tensorul pe care tocmai am refuzat să-l dăruim.
%%
%% Integritatea care acoperă o singură ieșire nu e integritate, e o iluzie
%% de integritate. `format_status/1` (OTP 25+) închide și această poartă:
%% supervizorul află CE a căzut, fără să afle CU CE.
-spec format_status(gen_server:format_status()) -> gen_server:format_status().
format_status(Status = #{state := State}) ->
    Status#{state => State#state{insight = redacted}};
format_status(Status) ->
    Status.

%%====================================================================
%% Intern
%%====================================================================

-spec offer_up(#state{}) -> ok.
offer_up(#state{insight = undefined}) ->
    %% Nimic de dăruit. Nu e o rușine — nu orice drum ajunge la o înțelegere.
    ok;
offer_up(#state{id = Id, insight = Insight}) ->
    %% `cast`, nu `call`: dacă bunul comun ar fi înghesuit sau chiar căzut în
    %% această clipă, ființa care pleacă nu trebuie să rămână blocată în ușă.
    %% Un dar care blochează pe cel ce-l face nu e chiar un dar.
    bahmet_commons:merge(Id, Insight).

-spec blend(bahmet_deep:tensor() | undefined, bahmet_deep:tensor()) ->
          bahmet_deep:tensor().
blend(undefined, Fresh) ->
    Fresh;
blend(Old, Fresh) ->
    {ok, Merged} = bahmet_deep:commune([Old, Fresh]),
    Merged.
