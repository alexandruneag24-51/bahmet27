%%%-------------------------------------------------------------------
%%% @doc bahmet_memory -- Bunul comun al cunoasterii.
%%%
%%% Tine memoria (vectorii, in Rust) si textele (cuvintele, aici). La o
%%% intrebare, cauta bucatile apropiate si le intoarce -- fara sa raspunda ea
%%% insasi. Raspunsul e treaba oracolului; asta e doar cine isi aminteste.
%%%
%%% ═══════════════════════════════════════════════════════════════════
%%%  DE CE NU ANTRENAM NIMIC
%%% ═══════════════════════════════════════════════════════════════════
%%%
%%% RAG bate ajustarea fina pentru „ce scrie in cartile mele", si nu de putin:
%%%
%%%   adaugi o carte noua in secunde, nu in saptamani
%%%   raspunsul poarta sursa cu el, deci poate fi verificat
%%%   sterge o sursa si dispare din raspunsuri imediat
%%%   nu inventeaza la fel de mult, fiindca are textul in fata
%%%
%%% Ajustarea fina schimba STILUL raspunsurilor, nu cunostintele. Sunt lucruri
%%% diferite, iar confuzia dintre ele costa luni.
%%%
%%% ═══════════════════════════════════════════════════════════════════
%%%  PERSISTAREA: UN SINGUR FISIER, SCRIS ATOMIC
%%% ═══════════════════════════════════════════════════════════════════
%%%
%%% Vectorii traiesc in Rust, textele aici. Doua jumatati care NU au voie sa se
%%% desincronizeze -- exact tiparul care a produs fiecare bug serios din acest
%%% proiect.
%%%
%%% De aceea sunt salvate impreuna, intr-un singur fisier, scris intr-un temporar
%%% si mutat prin `rename'. Redenumirea e atomica pe orice sistem de fisiere
%%% serios: fie vezi fisierul vechi intreg, fie pe cel nou intreg, niciodata
%%% ceva la mijloc. Acelasi principiu ca la confirmarea per DEK din rotatie.
%%%
%%% Depozitul ramane in RAM in timpul rularii. Pentru zeci de mii de bucati e
%%% mai mult decat destul; peste cateva sute de mii, vezi RAG.md §6.
%%%
%%% Impartirea in bucati e naiva: paragrafe, cu suprapunere. Functioneaza
%%% surprinzator de bine pe proza; pe cod sau tabele, mai putin.
%%% @end
%%%-------------------------------------------------------------------
-module(bahmet_memory).
-behaviour(gen_server).

-export([start_link/0,
         assimilate/2, assimilate/3,
         devour/1, devour_url/1,
         recall/1, recall/2,
         forget_source/1,
         save/0, save/1, load/0, load/1,
         status/0,
         chunk/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(CHUNK, 1200).      %% caractere per bucata (nu octeti -- vezi chunk/2)
-define(OVERLAP, 200).     %% suprapunere, ca sa nu taiem un gand in doua
-define(NEIGHBOURS, 5).    %% cate bucati intra in raspuns implicit

-record(fragment, {
    id      :: integer(),
    source  :: binary(),
    text    :: binary(),
    ordinal :: non_neg_integer()
}).

-record(state, {
    memory    :: bahmet_recall:memory(),
    dimension :: pos_integer(),
    fragments :: #{integer() => #fragment{}},
    next      :: integer()
}).

-define(SNAPSHOT_VERSION, 1).

%%====================================================================
%% API
%%====================================================================

-spec start_link() -> gen_server:start_ret().
start_link() -> gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Asimileaza un text intreg: il taie, il vectorizeaza, il tine minte.
%%
%% `Source' e eticheta prin care il poti uita mai tarziu -- calea unei carti,
%% adresa unei pagini. Fara ea, „uita tot ce ai citit de acolo" ar fi imposibil.
-spec assimilate(Source :: binary(), Text :: binary()) ->
          {ok, non_neg_integer()} | {error, term()}.
assimilate(Source, Text) -> assimilate(Source, Text, #{}).

-spec assimilate(binary(), binary(), map()) ->
          {ok, non_neg_integer()} | {error, term()}.
assimilate(Source, Text, Options) when is_binary(Source), is_binary(Text) ->
    %% Timp generos: vectorizarea unei carti inseamna sute de cereri catre
    %% oracol. Termenul e mare, dar exista -- ca peste tot in acest limbaj.
    gen_server:call(?SERVER, {assimilate, Source, Text, Options}, 600000).

%% @doc Bucatile cele mai apropiate de intrebare, cu sursa lor.
%%
%% NU raspunde. Intoarce ce isi aminteste, iar cine a intrebat decide ce face
%% cu asta -- de obicei, il da oracolului impreuna cu intrebarea.
-spec recall(binary()) -> {ok, [map()]} | {error, term()}.
recall(Question) -> recall(Question, ?NEIGHBOURS).

-spec recall(binary(), pos_integer()) -> {ok, [map()]} | {error, term()}.
recall(Question, K) -> gen_server:call(?SERVER, {recall, Question, K}, 60000).

%% @doc Uita tot ce a venit dintr-o sursa. Vectorii dispar, nu doar etichetele.
-spec forget_source(binary()) -> {ok, non_neg_integer()}.
forget_source(Source) -> gen_server:call(?SERVER, {forget_source, Source}, 60000).

%% @doc Citeste un fisier si il asimileaza. Text, Markdown, PDF sau HTML.
%%
%% Sursa devine calea fisierului, deci `forget_source' cu aceeasi cale sterge
%% exact ce a intrat de acolo.
-spec devour(file:filename()) -> {ok, non_neg_integer()} | {error, term()}.
devour(Path) ->
    case bahmet_scribe:read(Path) of
        {ok, Text} -> assimilate(unicode:characters_to_binary(Path), Text);
        {error, Why} -> {error, {scribe, Why}}
    end.

%% @doc Aduce o pagina web si o asimileaza.
-spec devour_url(string()) -> {ok, non_neg_integer()} | {error, term()}.
devour_url(Url) ->
    case bahmet_scribe:fetch(Url) of
        {ok, Text} -> assimilate(unicode:characters_to_binary(Url), Text);
        {error, Why} -> {error, {scribe, Why}}
    end.

%% @doc Salveaza tot -- vectori si texte -- intr-un singur fisier.
-spec save() -> ok | {error, term()}.
save() -> save(snapshot_path()).

-spec save(file:filename()) -> ok | {error, term()}.
save(Path) -> gen_server:call(?SERVER, {save, Path}, 300000).

%% @doc Incarca o memorie salvata, INLOCUIND-O pe cea curenta.
-spec load() -> {ok, non_neg_integer()} | {error, term()}.
load() -> load(snapshot_path()).

-spec load(file:filename()) -> {ok, non_neg_integer()} | {error, term()}.
load(Path) -> gen_server:call(?SERVER, {load, Path}, 300000).

-spec status() -> map().
status() -> gen_server:call(?SERVER, status, 5000).

%%====================================================================
%% gen_server
%%====================================================================

init([]) ->
    process_flag(trap_exit, true),
    try awaken() catch throw:{stop, Why} -> {stop, Why} end.

awaken() ->
    %% Masuram forma vectorilor, nu o presupunem. Acelasi principiu ca la
    %% `bahmet_entropy': verificam temelia la pornire, nu la prima cerere.
    case bahmet_oracle:dimension() of
        {ok, Dimension} ->
            %% Temelia se verifica la pornire, nu la prima salvare. Altfel ai
            %% afla ca biblioteca nativa e veche abia dupa ce ai asimilat o
            %% carte -- si ai pierde-o.
            ok = case bahmet_recall:verify() of
                     ok -> ok;
                     {error, Stale} -> throw({stop, Stale})
                 end,
            Fresh = #state{memory = bahmet_recall:open_memory(Dimension),
                           dimension = Dimension, fragments = #{}, next = 1},
            %% Daca exista un instantaneu, il luam. Altfel pornim goi -- si NU
            %% esuam: o memorie goala e o stare valida, un fisier lipsa nu e o
            %% eroare.
            {ok, revive(snapshot_path(), Fresh)};
        {error, Why} ->
            %% Fara oracol nu putem vectoriza nimic. Nu pornim pe jumatate.
            {stop, {oracle_unreachable, Why}}
    end.

handle_call({assimilate, Source, Text, Options}, _From, S) ->
    Size = maps:get(chunk, Options, ?CHUNK),
    Overlap = maps:get(overlap, Options, ?OVERLAP),
    Pieces = chunk(Text, {Size, Overlap}),
    case swallow(Pieces, Source, 0, S) of
        {ok, Count, Next} -> {reply, {ok, Count}, Next};
        {error, Why, Next} -> {reply, {error, Why}, Next}
    end;

handle_call({recall, Question, K}, _From, S) ->
    case bahmet_oracle:embed(Question) of
        {error, Why} ->
            {reply, {error, {oracle, Why}}, S};
        {ok, Query} ->
            case bahmet_recall:recall(S#state.memory, Query, K) of
                {error, Why} ->
                    {reply, {error, {memory, Why}}, S};
                Found ->
                    {reply, {ok, [dress(Id, Score, S) || {Id, Score} <- Found]}, S}
            end
    end;

handle_call({forget_source, Source}, _From, S) ->
    Doomed = [Id || {Id, #fragment{source = Src}} <- maps:to_list(S#state.fragments),
                    Src =:= Source],
    _ = [bahmet_recall:forget(S#state.memory, Id) || Id <- Doomed],
    Remaining = maps:without(Doomed, S#state.fragments),
    {reply, {ok, length(Doomed)}, S#state{fragments = Remaining}};

handle_call({save, Path}, _From, S) ->
    {reply, preserve(Path, S), S};

handle_call({load, Path}, _From, S) ->
    case resurrect(Path, S#state.dimension) of
        {ok, Next} -> {reply, {ok, maps:size(Next#state.fragments)}, Next};
        {error, Why} -> {reply, {error, Why}, S}
    end;

handle_call(status, _From, S) ->
    Sources = lists:usort([Src || #fragment{source = Src} <- maps:values(S#state.fragments)]),
    Reply = maps:merge(bahmet_recall:status(S#state.memory),
                       #{sources => Sources, fragments => maps:size(S#state.fragments)}),
    {reply, Reply, S};

handle_call(_Request, _From, S) ->
    {reply, {error, unknown_request}, S}.

handle_cast(_Msg, S) -> {noreply, S}.
handle_info(_Info, S) -> {noreply, S}.
%% Salvam la plecarea ordonata -- nu si la ruptura. Aceeasi distinctie ca la
%% contemplator: o stare pe jumatate scrisa, persistata, ar otravi fiecare
%% pornire viitoare.
terminate(Reason, S) when Reason =:= normal; Reason =:= shutdown ->
    _ = preserve(snapshot_path(), S),
    ok;
terminate({shutdown, _Why}, S) ->
    _ = preserve(snapshot_path(), S),
    ok;
terminate(_Broken, _S) ->
    ok.

code_change(_OldVsn, S, _Extra) -> {ok, S}.

%%====================================================================
%% Persistarea
%%====================================================================

%% Scriem intr-un temporar si mutam prin `rename'. Redenumirea e atomica pe
%% orice sistem de fisiere serios: fie vezi fisierul vechi intreg, fie pe cel
%% nou intreg, niciodata ceva la mijloc.
preserve(Path, S) ->
    Term = #{version => ?SNAPSHOT_VERSION,
             dimension => S#state.dimension,
             vectors => bahmet_recall:snapshot(S#state.memory),
             fragments => S#state.fragments,
             next => S#state.next},
    Temp = Path ++ ".tmp",
    ok = filelib:ensure_dir(Path),
    case file:write_file(Temp, term_to_binary(Term, [{compressed, 6}])) of
        ok ->
            case file:rename(Temp, Path) of
                ok ->
                    logger:notice("bahmet_memory: ~p fragmente salvate in ~ts",
                                  [maps:size(S#state.fragments), Path]),
                    ok;
                {error, Why} -> {error, {rename, Why}}
            end;
        {error, Why} ->
            {error, {write, Why}}
    end.

revive(Path, Fresh) ->
    case resurrect(Path, Fresh#state.dimension) of
        {ok, Loaded} ->
            logger:notice("bahmet_memory: ~p fragmente readuse din ~ts",
                          [maps:size(Loaded#state.fragments), Path]),
            Loaded;
        {error, enoent} ->
            Fresh;
        {error, Why} ->
            %% Un instantaneu stricat nu are voie sa opreasca pornirea, dar
            %% nici sa treaca in tacere: pornim goi si SPUNEM de ce.
            logger:warning("bahmet_memory: nu pot citi ~ts (~p). Pornesc gol.",
                           [Path, Why]),
            Fresh
    end.

resurrect(Path, Dimension) ->
    case file:read_file(Path) of
        {error, Why} ->
            {error, Why};
        {ok, Binary} ->
            try binary_to_term(Binary, [safe]) of
                #{version := ?SNAPSHOT_VERSION, dimension := Dimension,
                  vectors := Blob, fragments := Fragments, next := Next} ->
                    case bahmet_recall:restore(Blob) of
                        {error, Why} -> {error, {vectors, Why}};
                        Memory ->
                            {ok, #state{memory = Memory, dimension = Dimension,
                                        fragments = Fragments, next = Next}}
                    end;
                #{dimension := Other} when Other =/= Dimension ->
                    %% Ai schimbat modelul de embedding. Vectorii vechi nu mai
                    %% inseamna nimic in noul spatiu -- si nu e ceva ce putem
                    %% repara tacut, e ceva ce trebuie sa afli.
                    {error, {dimension_changed, Other, Dimension}};
                _ ->
                    {error, unknown_format}
            catch
                _:_ -> {error, corrupt}
            end
    end.

snapshot_path() ->
    application:get_env(bahmet, memory_file, "bahmet_memory.snapshot").

%%====================================================================
%% Intern
%%====================================================================

%% Vectorizam bucata cu bucata, oprindu-ne la primul esec.
%%
%% Alternativa -- sa continuam si sa raportam la sfarsit -- ar lasa o memorie
%% pe jumatate umpluta, care raspunde plauzibil dar incomplet. Un esec zgomotos
%% acum e mai bun decat raspunsuri care par bune si nu sunt.
swallow([], _Source, Count, S) ->
    {ok, Count, S};
swallow([Text | Rest], Source, Count, S) ->
    case bahmet_oracle:embed(Text) of
        {error, Why} ->
            {error, {oracle, Why}, S};
        {ok, Vector} ->
            Id = S#state.next,
            case bahmet_recall:remember(S#state.memory, Id, Vector) of
                {error, Why} ->
                    {error, {memory, Why}, S};
                ok ->
                    Fragment = #fragment{id = Id, source = Source,
                                         text = Text, ordinal = Count},
                    Next = S#state{
                        fragments = maps:put(Id, Fragment, S#state.fragments),
                        next = Id + 1
                    },
                    swallow(Rest, Source, Count + 1, Next)
            end
    end.

dress(Id, Score, S) ->
    case maps:get(Id, S#state.fragments, undefined) of
        undefined -> #{id => Id, score => Score, text => <<>>, source => <<"?">>};
        #fragment{source = Src, text = Text, ordinal = N} ->
            #{id => Id, score => Score, text => Text, source => Src, ordinal => N}
    end.

%% @doc Taie textul in bucati care se suprapun.
%%
%% Suprapunerea nu e risipa: fara ea, un gand taiat exact la granita ar fi pe
%% jumatate in fiecare bucata si intreg in niciuna, deci nu s-ar potrivi bine
%% cu nicio intrebare. Cele doua sute de caractere repetate sunt pretul ca
%% ideile de la margine sa ramana gasibile.
%% ═══════════════════════════════════════════════════════════════════
%%  TAIEM PE CARACTERE, NU PE OCTETI
%% ═══════════════════════════════════════════════════════════════════
%%
%% Prima versiune taia la octetul N. Pe text ASCII mergea perfect; pe primul
%% document cu diacritice a cazut, fiindca `ă' are doi octeti si `─' are trei.
%% O taietura la mijlocul unui caracter produce un binar care nu mai e text
%% valid -- `string:trim' il refuza cu `badarg', iar oracolul l-ar fi refuzat
%% si el.
%%
%% Lucram acum pe lista de puncte de cod. E ceva mai lent si complet imun:
%% nu exista taietura care sa rupa un caracter, fiindca nu mai taiem intre
%% octeti. `Size' inseamna de-acum caractere, ceea ce e oricum ce voiai sa
%% spui cand ai scris 1200.
-spec chunk(binary(), {pos_integer(), non_neg_integer()}) -> [binary()].
chunk(Text, {Size, Overlap}) when Overlap < Size ->
    Clean = re:replace(Text, "\\s+", " ", [global, {return, binary}]),
    Points = unicode:characters_to_list(Clean),
    slice(Points, Size, Overlap, []).

slice(Points, Size, _Overlap, Acc) when length(Points) =< Size ->
    lists:reverse(add(Points, Acc));
slice(Points, Size, Overlap, Acc) ->
    Cut = boundary(Points, Size),
    {Piece, _} = lists:split(Cut, Points),
    Step = max(1, Cut - Overlap),
    {_, Rest} = lists:split(Step, Points),
    slice(Rest, Size, Overlap, add(Piece, Acc)).

add(Points, Acc) ->
    case string:trim(unicode:characters_to_binary(Points)) of
        <<>> -> Acc;
        Trimmed -> [Trimmed | Acc]
    end.

%% Taiem la ultimul spatiu dinaintea limitei, ca sa nu rupem un cuvant.
%%
%% Daca nu exista niciun spatiu in a doua jumatate a bucatii -- un tabel, o
%% cale lunga, un bloc de cod -- taiem la limita. O bucata cu un cuvant rupt
%% e mai buna decat una de zece ori prea mare.
boundary(Points, Size) ->
    {Head, _} = lists:split(Size, Points),
    case last_space(Head, 1, 0) of
        Position when Position > Size div 2 -> Position;
        _ -> Size
    end.

last_space([], _Index, Found) -> Found;
last_space([$\s | Rest], Index, _Found) -> last_space(Rest, Index + 1, Index);
last_space([_ | Rest], Index, Found) -> last_space(Rest, Index + 1, Found).
