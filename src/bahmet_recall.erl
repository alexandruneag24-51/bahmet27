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

-export([open_memory/1, remember/3, forget/2, recall/3, status/1,
         snapshot/1, restore/1, verify/0]).
-export([compress/3, compress/4, recall_coded/3, code_of/2, glyph/1,
         coded_status/1]).

-nifs([open_memory/1, remember/3, forget/2, recall/3, status/1,
       snapshot/1, restore/1,
       compress/4, recall_coded/3, code_of/2, glyph/1, coded_status/1]).

-on_load(init/0).

-define(APPNAME, bahmet).
-define(LIBNAME, "libbahmet_recall").

-opaque memory() :: reference().
-opaque coded() :: reference().
-type vector() :: [float()].
-type code() :: [non_neg_integer()].
-export_type([memory/0, coded/0, vector/0, code/0]).

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

%% @doc Instantaneul memoriei, ca binar.
%%
%% Vectorii NU sunt secrete -- sunt numere derivate din text pe care oricum il
%% ai. De aceea `snapshot' exista, spre deosebire de `export_key' din seif:
%% asimetria de acolo protejeaza chei, iar aici nu e nimic de protejat.
%%
%% Formatul e explicit si versionat: "BHM1", dimensiune, numar, apoi perechi
%% de identitate si vector. Un fisier scris azi trebuie citit peste un an, de
%% un binar recompilat, fara surprize.
-spec snapshot(memory()) -> binary().
snapshot(_Memory) -> erlang:nif_error(nif_not_loaded).

%% @doc Reconstruieste memoria dintr-un instantaneu.
%%
%% Refuza orice nu are antetul asteptat, orice e trunchiat si orice contine
%% valori neterminate. O memorie pe jumatate restaurata ar raspunde plauzibil
%% si incomplet -- cel mai scump fel de esec.
-spec restore(binary()) ->
          memory() | {error, corrupt | unbounded_memory}.
restore(_Blob) -> erlang:nif_error(nif_not_loaded).

%%====================================================================
%% Codurile -- memoria comprimata (vezi native/bahmet_recall/src/pq.rs)
%%====================================================================

%% @doc Comprima o memorie in coduri scurte: `Parts' felii, fiecare
%% inlocuita de adresa celei mai apropiate dintre `Centroids' forme invatate.
%%
%% 4 x 256 da 4 octeti per amintire; 4 x 10000 da 8 octeti, dar tabele de
%% ~40 de ori mai mari. Masuratorile sunt in RAG.md, sectiunea 7.
%%
%% Rezultatul e o fotografie: amintirile adaugate dupa nu apar in ea.
-spec compress(memory(), Parts :: pos_integer(), Centroids :: pos_integer()) ->
          coded() | {error, dimension_discord | unbounded_memory}.
compress(Memory, Parts, Centroids) -> compress(Memory, Parts, Centroids, 8).

-spec compress(memory(), pos_integer(), pos_integer(), Iterations :: pos_integer()) ->
          coded() | {error, dimension_discord | unbounded_memory}.
compress(_Memory, _Parts, _Centroids, _Iterations) -> erlang:nif_error(nif_not_loaded).

%% @doc Cele mai apropiate `K' amintiri, dupa scorul aproximat din coduri.
-spec recall_coded(coded(), vector(), K :: pos_integer()) ->
          [{Id :: integer(), Score :: float()}] | {error, dimension_discord | not_finite}.
recall_coded(_Coded, _Query, _K) -> erlang:nif_error(nif_not_loaded).

%% @doc Codul unei amintiri: `Parts' numere.
-spec code_of(coded(), Id :: integer()) -> code() | {error, not_found}.
code_of(_Coded, _Id) -> erlang:nif_error(nif_not_loaded).

%% @doc Chipul unui cod, ca SVG: cate un semn cistercian pentru fiecare parte,
%% asezate in patrat. Fiecare parte trebuie sa fie cel mult 9999.
-spec glyph(code()) -> binary() | {error, not_representable}.
glyph(_Code) -> erlang:nif_error(nif_not_loaded).

-spec coded_status(coded()) ->
          #{dimension := pos_integer(), parts := pos_integer(),
            centroids := pos_integer(), remembered := non_neg_integer(),
            bytes := non_neg_integer(), full_bytes := non_neg_integer()}.
coded_status(_Coded) -> erlang:nif_error(nif_not_loaded).

%% @doc Verifica la pornire ca biblioteca nativa chiar are ce declara modulul.
%%
%% `-nifs' doar PERMITE inlocuirea unei functii, nu o cere. Daca biblioteca e
%% mai veche decat modulul -- pentru ca `cargo build' a esuat, iar `.so'-ul a
%% ramas cel de ieri -- incarcarea REUSESTE, functiile prezente merg normal,
%% iar cele lipsa raman stub-uri.
%%
%% Modul de esec e nesuferit: totul pare in regula pana la primul apel al
%% functiei lipsa, care poate veni dupa ce ai asimilat o carte intreaga.
%%
%% Deci verificam temelia la pornire, nu la prima folosire -- exact ce face
%% `bahmet_entropy'. O bucla completa pe o memorie de patru dimensiuni costa
%% microsecunde si transforma o descoperire tarzie intr-un refuz imediat.
-spec verify() -> ok | {error, {stale_library, term()}}.
verify() ->
    try
        Memory = open_memory(4),
        ok = remember(Memory, 1, [1.0, 0.0, 0.0, 0.0]),
        case restore(snapshot(Memory)) of
            {error, Why} ->
                {error, {stale_library, Why}};
            Restored ->
                case status(Restored) of
                    #{remembered := 1} -> ok;
                    Other -> {error, {stale_library, Other}}
                end
        end
    catch
        error:nif_not_loaded ->
            {error, {stale_library, "biblioteca nativa e mai veche decat modulul: ruleaza ./build.sh"}};
        Class:Reason ->
            {error, {stale_library, {Class, Reason}}}
    end.

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
