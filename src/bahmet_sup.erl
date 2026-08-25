%%%-------------------------------------------------------------------
%%% @doc bahmet_sup — Comuniunea. Perspectiva Globală Superioară.
%%%
%%% ═══════════════════════════════════════════════════════════════════
%%%  DE CE `rest_for_one` ESTE PERSPECTIVA GLOBALĂ
%%% ═══════════════════════════════════════════════════════════════════
%%%
%%% Nicio ființă din sistem nu știe de ce a murit vecina ei. Un contemplator
%%% știe doar propria stare; temelia știe doar propriile ponderi. Fiecare are
%%% o vedere locală, adevărată dar parțială.
%%%
%%% Supervizorul e singurul care deține informația pe care nimeni altcineva nu
%%% o poate avea: **cine depinde de cine**. Iar `rest_for_one` este forma în
%%% care acea cunoaștere devine executabilă.
%%%
%%% Ordinea copiilor de mai jos NU este stilistică — este un graf de dependență:
%%%
%%%     bahmet_ground  ──►  bahmet_commons  ──►  bahmet_council_sup
%%%     (temelia)           (bunul comun)        (adunarea)
%%%
%%% `rest_for_one` spune: dacă un copil cade, repornește-l pe el și pe TOȚI
%%% cei porniți DUPĂ el, în ordine — și nu atinge pe niciunul dinaintea lui.
%%%
%%% Ce cumpără asta concret:
%%%
%%%   • Dacă temelia cade, `ground()`-ul pe care contemplatorii îl țin devine
%%%     o resursă orfană. Ei nu au cum să *afle* asta singuri — ar continua
%%%     să calculeze pe un pământ care nu mai există. Supervizorul, care vede
%%%     întregul, îi refondează pe toți. Vederea locală nu ar fi putut niciodată
%%%     produce această decizie.
%%%
%%%   • Dacă adunarea cade, temelia și bunul comun rămân NEATINSE. Înțelepciunea
%%%     adunată de generațiile anterioare de ființe supraviețuiește căderii celor
%%%     vii. Un `one_for_all` ar fi șters tocmai ce a fost câștigat cu greu —
%%%     ar fi o perspectivă globală *panicată*, nu una superioară.
%%%
%%% Diferența dintre o strategie și un reflex este exact aceasta: strategia
%%% știe ce să NU repornească.
%%% @end
%%%-------------------------------------------------------------------
-module(bahmet_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-define(SERVER, ?MODULE).

%% Răgazul acordat unui copil ca să-și încheie treburile la oprire.
%% Nu e o toleranță tehnică: este timpul în care un contemplator apucă să-și
%% verse înțelegerea în bunul comun înainte să se stingă. Chiar și la plecare
%% forțată, i se lasă răgaz să dăruiască. `brutal_kill` ar fi negat asta.
-define(GRACE, 5000).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->

    SupFlags = #{
        strategy  => rest_for_one,

        %% ÎNGĂDUINȚA (forbearance). `intensity`/`period` = 3 căderi în 60s.
        %%
        %% Un supervizor fără limită nu e răbdător, e orb: ar reporni la
        %% infinit un copil care nu poate porni, arzând un nucleu întreg și
        %% ascunzând problema reală de sub ochii tuturor.
        %%
        %% Când pragul e depășit, supervizorul face lucrul greu: **renunță la
        %% propria autoritate** și moare, predând situația unei vederi mai largi
        %% (aici: mașina virtuală / operatorul). Aceasta e smerenia codificată
        %% arhitectural — a recunoaște că perspectiva ta, oricât de globală, tot
        %% e mărginită, și a preda ștafeta la timp în loc să te încăpățânezi.
        intensity => 3,
        period    => 60,

        %% Rădăcina nu se stinge singură niciodată. Adunările vin și trec;
        %% temelia și înțelepciunea rămân.
        auto_shutdown => never
    },

    %% ── 1. TEMELIA ──────────────────────────────────────────────────
    %% Prima, fiindcă totul se sprijină pe ea. `permanent`: un cerc fără
    %% temelie nu are ce contempla.
    Ground = #{
        id       => bahmet_ground,
        start    => {bahmet_ground, start_link, []},
        restart  => permanent,
        shutdown => ?GRACE,
        type     => worker,
        modules  => [bahmet_ground]
    },

    %% ── 2. BUNUL COMUN ──────────────────────────────────────────────
    %% După temelie (înțelepciunea e făcută din tensori care au forma
    %% temeliei), înaintea adunării (trebuie să existe cineva care să
    %% primească darurile înainte ca cineva să aibă ce dărui).
    Commons = #{
        id       => bahmet_commons,
        start    => {bahmet_commons, start_link, []},
        restart  => permanent,
        shutdown => ?GRACE,
        type     => worker,
        modules  => [bahmet_commons]
    },

    %% ── 3. ADUNAREA ─────────────────────────────────────────────────
    %% `transient`, nu `permanent`. Aceasta e distincția centrală a
    %% proiectului, exprimată într-un singur cuvânt:
    %%
    %%   permanent → „vreau ca acest lucru să existe mereu"
    %%   transient → „vreau ca acest lucru să reușească"
    %%
    %% O adunare care și-a împlinit lucrarea se stinge NORMAL. `transient`
    %% înseamnă că supervizorul recunoaște terminarea normală drept izbândă
    %% și o lasă în pace. `permanent` ar reînvia-o la nesfârșit — ceea ce nu
    %% e grijă, e incapacitatea de a accepta că ceva s-a terminat.
    %%
    %% `shutdown => infinity` e obligatoriu pentru copiii de tip supervizor:
    %% un supervizor trebuie să-și oprească întâi întregul subarbore, iar noi
    %% nu avem dreptul să punem un cronometru peste plecarea altora.
    Gathering = #{
        id       => bahmet_council_sup,
        start    => {bahmet_council_sup, start_link, []},
        restart  => transient,
        shutdown => infinity,
        type     => supervisor,
        modules  => [bahmet_council_sup]
    },

    {ok, {SupFlags, [Ground, Commons, Gathering]}}.
