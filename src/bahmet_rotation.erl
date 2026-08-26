%%%-------------------------------------------------------------------
%%% @doc bahmet_rotation -- Reimpachetarea.
%%%
%%% ═══════════════════════════════════════════════════════════════════
%%%  CEA MAI PERICULOASA OPERATIE DIN SISTEM
%%% ═══════════════════════════════════════════════════════════════════
%%%
%%% Rotatia cheilor nu esueaza zgomotos cand e gresita. Distruge date, tacut
%%% si ireversibil. De aceea ordinea de mai jos e mai importanta decat orice
%%% altceva din acest modul, iar comentariile explica de ce fiecare pas e
%%% acolo unde e.
%%%
%%%   1. `stage(Tinta)'   -- cheia noua devine DISPONIBILA, nu curenta.
%%%                          Din clipa asta AMBELE generatii pot desface.
%%%   2. reimpachetare    -- lot cu lot, cu VERIFICARE inainte de confirmare,
%%%                          fiecare confirmare atomica in depozit.
%%%   3. `promote(Tinta)' -- abia dupa ce NU a mai ramas nimic in urma.
%%%
%%% Ce NU facem: nu distrugem cheia veche. Vezi sectiunea despre retragere.
%%%
%%% ═══════════════════════════════════════════════════════════════════
%%%  RELUAREA E GRATUITA
%%% ═══════════════════════════════════════════════════════════════════
%%%
%%% Nu exista jurnal de progres, si asta e o alegere, nu o omisiune.
%%%
%%% Subcheile se DERIVA din radacina (`KEK_n = HKDF(radacina, n)'), deci
%%% `stage' pe aceeasi tinta produce mereu aceeasi cheie, chiar dupa o
%%% repornire completa a masinii virtuale. Iar fiecare DEK isi poarta
%%% generatia in depozit, deci cei deja mutati pur si simplu nu mai apar in
%%% `pending'.
%%%
%%% Rezultatul: o rotatie cazuta la jumatate se reia singura la urmatoarea
%%% incercare, fara nicio stare de reconciliat. Progresul nu se memoreaza,
%%% se recalculeaza. Ce nu memorezi nu se poate desincroniza.
%%%
%%% ═══════════════════════════════════════════════════════════════════
%%%  DE CE NU RETRAGEM AUTOMAT GENERATIA VECHE
%%% ═══════════════════════════════════════════════════════════════════
%%%
%%% Fiindca vechea cheie e singurul lucru care mai poate recupera un DEK
%%% scapat din vedere. Sa o retragem automat, imediat dupa rotatie, ar
%%% inseamna sa distrugem plasa de siguranta exact in clipa in care s-ar
%%% putea dovedi necesara.
%%%
%%% Retragerea e o decizie de operator, luata dupa ce cineva s-a uitat la
%%% `bahmet_dek_store:tally()' si a vazut ca nu a ramas nimeni in urma.
%%% Automatizarea „ajutatoare" care distruge date e cea mai scumpa forma de
%%% bunavointa.
%%% @end
%%%-------------------------------------------------------------------
-module(bahmet_rotation).
-behaviour(gen_server).

-export([start_link/0, rotate_now/0, due_in/0, status/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(PERIOD_MS, 2592000000).   %% 30 de zile
%% Loturi mici, deliberat: fiecare lot e o pauza in care alte procese respira,
%% iar o cadere pierde cel mult atat.
-define(BATCH, 64).

-record(state, {
    last      :: integer(),
    rotations = 0 :: non_neg_integer(),
    last_result = none :: none | {ok, non_neg_integer()} | {error, term()}
}).

%%====================================================================
%% API
%%====================================================================

-spec start_link() -> gen_server:start_ret().
start_link() -> gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec rotate_now() -> {ok, non_neg_integer()} | {error, term()}.
rotate_now() -> gen_server:call(?SERVER, rotate, 120000).

-spec due_in() -> integer().
due_in() -> gen_server:call(?SERVER, due_in, 5000).

-spec status() -> map().
status() -> gen_server:call(?SERVER, status, 5000).

%%====================================================================
%% gen_server
%%====================================================================

init([]) ->
    {ok, #state{last = erlang:monotonic_time(millisecond)}, ?PERIOD_MS}.

handle_call(rotate, _From, S) ->
    {Reply, Next} = perform(S),
    {reply, Reply, Next, ?PERIOD_MS};
handle_call(due_in, _From, S) ->
    Elapsed = erlang:monotonic_time(millisecond) - S#state.last,
    {reply, max(0, ?PERIOD_MS - Elapsed), S, ?PERIOD_MS};
handle_call(status, _From, S) ->
    {reply, #{rotations => S#state.rotations,
              last_result => S#state.last_result,
              tally => bahmet_dek_store:tally()}, S, ?PERIOD_MS};
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
%% Rotatia
%%====================================================================

perform(S) ->
    Current = bahmet_keyring:generation(),
    Target = Current + 1,

    %% PASUL 1. Cheia noua devine disponibila INAINTE sa rescriem ceva.
    %% Din clipa asta ambele generatii pot desface, deci o cadere la mijloc
    %% lasa in urma un amestec perfect lizibil, nu date pierdute.
    {ok, Fresh} = bahmet_keyring:stage(Target),
    Started = erlang:monotonic_time(millisecond),

    case rewrap_all(Target, Fresh, 0) of
        {ok, Count} ->
            %% PASUL 3. Abia acum, cand `pending' e gol.
            ok = bahmet_keyring:promote(Target),
            Elapsed = erlang:monotonic_time(millisecond) - Started,
            logger:notice("bahmet_rotation: generatia ~p, ~p chei reimpachetate in ~p ms. "
                          "Generatia ~p ramane disponibila; retrage-o manual dupa verificare.",
                          [Target, Count, Elapsed, Current]),
            {{ok, Count}, S#state{last = erlang:monotonic_time(millisecond),
                                  rotations = S#state.rotations + 1,
                                  last_result = {ok, Count}}};
        {error, Why} ->
            %% NU promovam. Generatia curenta ramane `Current', deci
            %% urmatoarea incercare tinteste acelasi `Target', deriva aceeasi
            %% cheie si reia exact de unde s-a oprit. Cei deja mutati raman
            %% valizi: cheia tinta ramane disponibila.
            logger:error("bahmet_rotation: rotatia catre generatia ~p s-a oprit: ~p. "
                         "Nimic nu s-a pierdut; reluarea continua de unde a ramas.",
                         [Target, Why]),
            {{error, Why}, S#state{last_result = {error, Why}}}
    end.

%% Cat timp mai exista cineva care nu e la tinta, mai ia un lot.
%%
%% Nu tinem continuare de la `dets:select': dupa fiecare confirmare, randurile
%% rescrise ies singure din filtru. O interogare noua e mereu corecta; o
%% continuare pastrata ar minti dupa o cadere.
rewrap_all(Target, Fresh, Done) ->
    case bahmet_dek_store:pending(Target, ?BATCH) of
        [] ->
            {ok, Done};
        Batch ->
            case rewrap_batch(Batch, Target, Fresh, 0) of
                {ok, Moved} -> rewrap_all(Target, Fresh, Done + Moved);
                {error, Why} -> {error, Why}
            end
    end.

rewrap_batch([], _Target, _Fresh, Moved) ->
    {ok, Moved};
rewrap_batch([Dek | Rest], Target, Fresh, Moved) ->
    case rewrap_one(Dek, Target, Fresh) of
        ok -> rewrap_batch(Rest, Target, Fresh, Moved + 1);
        {error, Why} -> {error, Why}
    end.

rewrap_one({Id, From, Wrapped, Aad}, Target, Fresh) ->
    case bahmet_keyring:key_for(From) of
        {error, retired} ->
            %% Cheia care l-ar putea desface nu mai e servita. Datele acestui
            %% DEK sunt deja inaccesibile. NU tacem si NU sarim peste el:
            %% oprim rotatia, ca operatorul sa afle acum, nu peste sase luni.
            {error, {generation_retired, From, Id}};
        {ok, Old} ->
            case bahmet_vault:unwrap_key(Old, Wrapped, Aad, From) of
                {error, Why} ->
                    {error, {unwrap_failed, Id, Why}};
                Dek ->
                    Result = reseal(Id, Dek, Fresh, Aad, Target),
                    %% Handle-ul deschis nu are voie sa supravietuiasca
                    %% operatiei, indiferent cum s-a terminat.
                    _ = bahmet_vault:shred(Dek),
                    Result
            end
    end.

reseal(Id, Dek, Fresh, Aad, Target) ->
    case bahmet_vault:wrap_key(Fresh, Dek, Aad) of
        {error, Why} -> {error, {wrap_failed, Id, Why}};
        {ok, Rewrapped} -> verify_then_commit(Id, Dek, Fresh, Rewrapped, Aad, Target)
    end.

%% VERIFICAREA. Inima intregii proceduri.
%%
%% Inainte de a suprascrie o inregistrare care functiona, desfacem forma noua
%% cu cheia noua si comparam amprentele. Daca nu se potrivesc, nu confirmam --
%% depozitul pastreaza forma veche, care se deschide inca.
%%
%% Amprentele fac asta posibil fara sa expuna nimic: 8 octeti ireversibili
%% care spun „e aceeasi cheie" fara sa spuna ce cheie e. Aceeasi unealta
%% construita pentru jurnale de audit se dovedeste a fi exact ce trebuie
%% pentru a demonstra ca o transformare a pastrat ce trebuia sa pastreze.
verify_then_commit(Id, Original, Fresh, Rewrapped, Aad, Target) ->
    case bahmet_vault:unwrap_key(Fresh, Rewrapped, Aad, Target) of
        {error, Why} ->
            {error, {verify_failed, Id, Why}};
        Check ->
            Matches = bahmet_vault:fingerprint(Check)
                          =:= bahmet_vault:fingerprint(Original),
            _ = bahmet_vault:shred(Check),
            case Matches of
                true ->
                    %% Confirmare atomica. O cadere imediat dupa asta lasa
                    %% depozitul consistent, nu pe jumatate scris.
                    bahmet_dek_store:commit(Id, Target, Rewrapped);
                false ->
                    {error, {fingerprint_mismatch, Id}}
            end
    end.
