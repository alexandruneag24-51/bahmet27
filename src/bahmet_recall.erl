%%%-------------------------------------------------------------------
%%% @doc bahmet_recall -- Puntea catre memorie.
%%%
%%% Rust tine NUMERELE, Erlang tine CUVINTELE. Impartirea nu e arbitrara:
%%% cautarea prin similaritate e aritmetica pura peste un bloc contiguu de
%%% memorie, exact ce face Rust bine; iar textele, sursele si metadatele sunt
%%% stare care trebuie supravegheata, exact ce face BEAM bine.
%%%
%%% O memorie e un `#Ref<>' opac, ca si o cheie. Nu poti citi vectorii din
%%% Erlang -- si nici nu ai de ce: ai identitatile, iar cuvintele sunt la tine.
%%% @end
%%%-------------------------------------------------------------------
-module(bahmet_recall).

-export([open_memory/1, remember/3, forget/2, recall/3, status/1]).

-nifs([open_memory/1, remember/3, forget/2, recall/3, status/1]).

-on_load(init/0).

-define(APPNAME, bahmet).
-define(LIBNAME, "libbahmet_recall").

-opaque memory() :: reference().
-type vector() :: [float()].
-export_type([memory/0, vector/0]).

%% @doc Deschide o memorie de o forma anume.
%%
%% Dimensiunea NU se presupune -- se masoara o data, cu
%% `bahmet_oracle:dimension/0'. Un sistem care presupune 768 si primeste 1024
%% nu esueaza zgomotos: umple memoria cu vectori de forma gresita si intoarce
%% vecini absurzi, luni la rand.
-spec open_memory(Dimension :: pos_integer()) ->
          memory() | {error, unbounded_memory}.
open_memory(_Dimension) -> erlang:nif_error(nif_not_loaded).

%% @doc Adauga o amintire. Vectorul e normalizat la inserare.
-spec remember(memory(), Id :: integer(), vector()) ->
          ok | {error, dimension_discord | not_finite}.
remember(_Memory, _Id, _Vector) -> erlang:nif_error(nif_not_loaded).

%% @doc Sterge o amintire -- si vectorul, nu doar identitatea.
%% Intoarce cate au fost sterse.
-spec forget(memory(), Id :: integer()) -> non_neg_integer().
forget(_Memory, _Id) -> erlang:nif_error(nif_not_loaded).

%% @doc Cele mai apropiate `K' amintiri, ordonate descrescator dupa cosinus.
%%
%% Ruleaza pe planificator murdar: o cautare peste un corpus mare poate dura
%% zeci de milisecunde, iar un NIF care tine un planificator normal atat de
%% mult infometeaza toate celelalte fiinte de pe acel fir.
-spec recall(memory(), vector(), K :: pos_integer()) ->
          [{Id :: integer(), Score :: float()}] | {error, dimension_discord | not_finite}.
recall(_Memory, _Query, _K) -> erlang:nif_error(nif_not_loaded).

-spec status(memory()) ->
          #{dimension := pos_integer(), remembered := non_neg_integer()}.
status(_Memory) -> erlang:nif_error(nif_not_loaded).

init() ->
    SoName =
        case code:priv_dir(?APPNAME) of
            {error, bad_name} ->
                case filelib:is_dir(filename:join("..", "priv")) of
                    true  -> filename:join(["..", "priv", ?LIBNAME]);
                    false -> filename:join("priv", ?LIBNAME)
                end;
            Dir ->
                filename:join(Dir, ?LIBNAME)
        end,
    erlang:load_nif(SoName, 0).
