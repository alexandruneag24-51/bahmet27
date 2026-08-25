%%%-------------------------------------------------------------------
%%% @doc bahmet_deep — Puntea către Adânc.
%%%
%%% Acest modul nu conține logică. Este o *promisiune*: fiecare funcție de
%%% aici există în două forme — stub-ul Erlang scris mai jos și implementarea
%%% Rust care îl înlocuiește la încărcare. Dacă biblioteca nativă lipsește,
%%% stub-ul se declanșează cu `nif_not_loaded` și supervizorul află imediat,
%%% în loc ca sistemul să pornească pe jumătate și să eșueze mai târziu, în
%%% mijlocul unui calcul.
%%%
%%% Faptul că puntea e un modul separat, subțire și fără stare, este
%%% intenționat: Adâncul e o *unealtă* a cercului, nu un membru al lui.
%%% Nu supraveghem acest modul; supraveghem ființa care îl ține (bahmet_ground).
%%% @end
%%%-------------------------------------------------------------------
-module(bahmet_deep).

-export([open_ground/2, intuit/2, commune/1, reflect/1]).

%% OTP 25+: declarația `-nifs` spune explicit compilatorului care funcții
%% pot fi înlocuite de cod nativ. Fără ea, compilatorul are voie să facă
%% optimizări (inline, propagare de tipuri) care ar contrazice tăcut
%% implementarea reală. Onestitatea față de compilator e tot o formă de
%% siguranță.
-nifs([open_ground/2, intuit/2, commune/1, reflect/1]).

-on_load(init/0).

-define(APPNAME, bahmet).
-define(LIBNAME, "libbahmet_deep").

%% O temelie este un termen de resursă, opac. BEAM îl reprezintă ca referință
%% și îi numără proprietarii; când ultimul dispare, Rust primește `Drop`.
%% Nu există `close_ground/1` — și nici nevoie de disciplina de a-l apela.
-opaque ground() :: reference().
-type tensor() :: [float()].
-export_type([ground/0, tensor/0]).

%%====================================================================
%% API
%%====================================================================

%% @doc Deschide o temelie deterministă de dimensiune `Dimension'.
%% Se declanșează cu `unbounded_ground' dacă dimensiunea e 0 sau > 2048.
-spec open_ground(Dimension :: pos_integer(), Seed :: non_neg_integer()) ->
          ground().
open_ground(_Dimension, _Seed) ->
    erlang:nif_error(nif_not_loaded).

%% @doc Intuiție: o ofrandă intră, o distribuție de probabilitate iese.
%%
%% Rulează pe un planificator murdar. Din perspectiva procesului apelant,
%% arată exact ca orice altă funcție care durează — dar nu blochează pe
%% nimeni altcineva. Aceasta e diferența dintre a fi ocupat și a fi lacom.
%%
%% Se declanșează cu `dimension_discord' dacă ofranda nu are forma temeliei.
%% Nu prindem asta cu try/catch: e o eroare de apelant, iar în OTP erorile
%% de apelant urcă la supervizor, care are perspectiva necesară ca să decidă.
-spec intuit(ground(), tensor()) -> {ok, tensor()}.
intuit(_Ground, _Offering) ->
    erlang:nif_error(nif_not_loaded).

%% @doc Comuniune: topește o listă de înțelegeri în centroidul lor.
%% Nicio ofrandă nu domină; toate cântăresc la fel.
-spec commune([tensor(), ...]) -> {ok, tensor()}.
commune(_Offerings) ->
    erlang:nif_error(nif_not_loaded).

%% @doc Introspecție: ce știe temelia despre propria activitate.
-spec reflect(ground()) ->
          #{dimension    := pos_integer(),
            intuitions   := non_neg_integer(),
            refusals     := non_neg_integer(),
            last_entropy := float(),
            max_entropy  := float(),
            coherence    := float()}.
reflect(_Ground) ->
    erlang:nif_error(nif_not_loaded).

%%====================================================================
%% Încărcare
%%====================================================================

-spec init() -> ok | {error, term()}.
init() ->
    SoName =
        case code:priv_dir(?APPNAME) of
            {error, bad_name} ->
                %% Rulăm dintr-un arbore de surse, nu dintr-o release.
                case filelib:is_dir(filename:join("..", "priv")) of
                    true  -> filename:join(["..", "priv", ?LIBNAME]);
                    false -> filename:join("priv", ?LIBNAME)
                end;
            Dir ->
                filename:join(Dir, ?LIBNAME)
        end,
    %% Fără extensie: BEAM adaugă singur .so / .dll / .dylib.
    erlang:load_nif(SoName, 0).
