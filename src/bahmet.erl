%%%-------------------------------------------------------------------
%%% @doc bahmet -- Consola.
%%%
%%% Modulul asta nu adauga nicio capacitate. Face doar ca cele existente sa
%%% incapa intr-un rand pe care il tastezi fara sa te gandesti.
%%%
%%% Sunt lucruri diferite: `bahmet_memory' si `bahmet_oracle' sunt piese de
%%% sistem, cu argumente explicite si erori intoarse. Asta e o interfata
%%% pentru un om obosit la ora unsprezece seara, care vrea sa intrebe ceva.
%%%
%%%   bahmet:learn("carte.pdf").
%%%   bahmet:ask("ce spune despre rabdare?").
%%%   bahmet:sources().
%%%
%%% Accepta si siruri, si binare. Diacriticele merg. Memoria porneste singura.
%%% @end
%%%-------------------------------------------------------------------
-module(bahmet).

-export([help/0,
         learn/1, learn_url/1, learn_dir/1,
         ask/1, ask/2, answer/1,
         find/1, find/2,
         see/2,
         forget/1, sources/0, status/0, save/0]).

%% Cate fragmente intra in context. Peste vreo 8, modelele mici incep sa
%% piarda firul: contextul lung nu inseamna atentie lunga.
-define(NEIGHBOURS, 5).

%%====================================================================

-spec help() -> ok.
help() ->
    io:format(
      "~n  BAHMET 27 — consola~n~n"
      "  bahmet:learn(\"carte.pdf\")        citeste un fisier (txt, md, pdf, html)~n"
      "  bahmet:learn_dir(\"carti/\")       citeste tot ce poate dintr-un director~n"
      "  bahmet:learn_url(\"https://...\")  citeste o pagina web~n~n"
      "  bahmet:ask(\"intrebarea ta\")      raspunde din ce a citit~n"
      "  bahmet:find(\"cuvinte cheie\")     arata doar ce isi aminteste, fara raspuns~n"
      "  bahmet:see(\"ce e asta?\", \"poza.png\")   intreaba despre o imagine~n~n"
      "  bahmet:sources()                  ce a citit pana acum~n"
      "  bahmet:forget(\"carte.pdf\")       uita o sursa~n"
      "  bahmet:status()                   cate fragmente, ce dimensiune~n"
      "  bahmet:save()                     salveaza memoria pe disc~n~n"
      "  Memoria se salveaza si singura la iesire. `q().' ca sa iesi.~n~n"),
    ok.

%%====================================================================
%% Citire
%%====================================================================

-spec learn(file:filename()) -> ok | {error, term()}.
learn(Path) ->
    with_memory(fun() ->
        io:format("  citesc ~ts ...~n", [Path]),
        case bahmet_memory:devour(Path) of
            {ok, Count} ->
                io:format("  ~p fragmente.~n", [Count]),
                ok;
            {error, Why} ->
                complain(Why)
        end
    end).

-spec learn_url(string()) -> ok | {error, term()}.
learn_url(Url) ->
    with_memory(fun() ->
        io:format("  aduc ~ts ...~n", [Url]),
        case bahmet_memory:devour_url(Url) of
            {ok, Count} ->
                io:format("  ~p fragmente.~n", [Count]),
                ok;
            {error, Why} ->
                complain(Why)
        end
    end).

%% @doc Citeste tot ce poate dintr-un director. Sare peste ce nu intelege,
%% si SPUNE peste ce a sarit -- un fisier ignorat in tacere e un fisier pe
%% care il crezi citit.
-spec learn_dir(file:filename()) -> ok.
learn_dir(Dir) ->
    with_memory(fun() ->
        {ok, Entries} = file:list_dir(Dir),
        Paths = [filename:join(Dir, E) || E <- lists:sort(Entries)],
        Files = [P || P <- Paths, filelib:is_regular(P)],
        {Known, Unknown} = lists:partition(
            fun(P) -> bahmet_scribe:kind(P) =/= unknown end, Files),
        _ = [learn(P) || P <- Known],
        case Unknown of
            [] -> ok;
            _ -> io:format("  sarite (format necunoscut): ~p~n", [length(Unknown)])
        end,
        ok
    end).

%%====================================================================
%% Intrebare
%%====================================================================

-spec ask(string() | binary()) -> ok | {error, term()}.
ask(Question) -> ask(Question, ?NEIGHBOURS).

-spec ask(string() | binary(), pos_integer()) -> ok | {error, term()}.
ask(Question, K) ->
    case answer(text(Question), K) of
        {ok, Reply, Sources} ->
            io:format("~n~ts~n~n  surse: ~ts~n~n", [Reply, join(Sources)]),
            ok;
        {error, Why} ->
            complain(Why)
    end.

%% @doc Ca `ask', dar intoarce in loc sa tipareasca. Pentru cand construiesti
%% ceva peste.
-spec answer(string() | binary()) ->
          {ok, binary(), [binary()]} | {error, term()}.
answer(Question) -> answer(text(Question), ?NEIGHBOURS).

answer(Question, K) ->
    with_memory(fun() ->
        case bahmet_memory:recall(Question, K) of
            {error, Why} ->
                {error, Why};
            {ok, []} ->
                {error, memoria_e_goala};
            {ok, Found} ->
                Sources = lists:usort([maps:get(source, F) || F <- Found]),
                case bahmet_oracle:ask(prompt(Question, Found)) of
                    {ok, Reply} -> {ok, string:trim(Reply), Sources};
                    {error, Why} -> {error, {oracol, Why}}
                end
        end
    end).

%% Instructiunea e jumatate din calitatea raspunsului.
%%
%% „Foloseste DOAR" impiedica modelul sa completeze din ce stie -- fara ea, nu
%% mai poti distinge ce a citit de ce a inventat, iar sursele de dedesubt devin
%% o minciuna politicoasa.
%%
%% „Spune ca nu gasesti" ii da o iesire onorabila. Un model caruia nu i se
%% permite sa nu stie va inventa, fiindca tacerea nu e printre optiuni.
prompt(Question, Found) ->
    Context = iolist_to_binary(
        [[<<"[">>, maps:get(source, F), <<"]\n">>, maps:get(text, F), <<"\n\n">>]
         || F <- Found]),
    <<"Raspunzi STRICT pe baza fragmentelor de mai jos.\n\n"
      "Reguli:\n"
      "- Foloseste DOAR informatia din fragmente.\n"
      "- Daca fragmentele nu contin raspunsul, spune exact: "
      "\"Nu gasesc raspunsul in ce am citit.\"\n"
      "- Nu completa din cunostinte generale.\n"
      "- Raspunde in aceeasi limba ca intrebarea, concis.\n\n"
      "FRAGMENTE:\n", Context/binary,
      "\nINTREBARE: ", Question/binary>>.

%% @doc Ce isi aminteste, fara sa raspunda.
%%
%% Util cand un raspuns pare gresit: vezi imediat daca problema e la cautare
%% (fragmente nepotrivite) sau la model (fragmente bune, raspuns prost). Doua
%% remedii complet diferite.
-spec find(string() | binary()) -> ok.
find(Question) -> find(Question, ?NEIGHBOURS).

-spec find(string() | binary(), pos_integer()) -> ok.
find(Question, K) ->
    with_memory(fun() ->
        case bahmet_memory:recall(text(Question), K) of
            {error, Why} ->
                complain(Why);
            {ok, Found} ->
                io:format("~n"),
                _ = [io:format("  ~.3f  ~ts~n         ~ts...~n~n",
                               [maps:get(score, F), maps:get(source, F),
                                snippet(maps:get(text, F))])
                     || F <- Found],
                ok
        end
    end).

%% @doc Intreaba despre o imagine. Cere `ollama pull llava:7b'.
-spec see(string() | binary(), file:filename()) -> ok | {error, term()}.
see(Prompt, ImagePath) ->
    case file:read_file(ImagePath) of
        {error, Why} ->
            complain({nu_pot_citi, ImagePath, Why});
        {ok, Bytes} ->
            io:format("  ma uit la ~ts ...~n", [ImagePath]),
            case bahmet_oracle:see(text(Prompt), Bytes) of
                {ok, Reply} -> io:format("~n~ts~n~n", [string:trim(Reply)]), ok;
                {error, Why} -> complain({oracol, Why})
            end
    end.

%%====================================================================
%% Memorie
%%====================================================================

-spec forget(string() | binary()) -> ok.
forget(Source) ->
    with_memory(fun() ->
        {ok, Count} = bahmet_memory:forget_source(text(Source)),
        io:format("  ~p fragmente uitate.~n", [Count]),
        ok
    end).

-spec sources() -> ok.
sources() ->
    with_memory(fun() ->
        #{sources := Known} = bahmet_memory:status(),
        case Known of
            [] -> io:format("  nimic citit inca.~n");
            _ -> _ = [io:format("  ~ts~n", [S]) || S <- Known], ok
        end,
        ok
    end).

-spec status() -> ok.
status() ->
    with_memory(fun() ->
        #{fragments := N, dimension := D, sources := S} = bahmet_memory:status(),
        io:format("  ~p fragmente din ~p surse, vectori de ~p dimensiuni.~n",
                  [N, length(S), D]),
        ok
    end).

-spec save() -> ok.
save() ->
    with_memory(fun() -> bahmet_memory:save() end).

%%====================================================================
%% Intern
%%====================================================================

%% Porneste memoria daca nu e pornita. `unlink' fiindca o cadere a memoriei nu
%% are voie sa ia cu ea consola din care ai chemat-o.
with_memory(Work) ->
    case whereis(bahmet_memory) of
        undefined ->
            case bahmet_memory:start_link() of
                {ok, Pid} -> unlink(Pid), Work();
                {error, {already_started, _}} -> Work();
                {error, {oracle_unreachable, _}} ->
                    io:format("~n  Ollama nu raspunde. Porneste-l:~n"
                              "    ollama serve~n"
                              "  sau verifica modelele:~n"
                              "    ollama list~n~n"),
                    {error, fara_oracol};
                {error, Why} ->
                    complain(Why)
            end;
        _ ->
            Work()
    end.

complain(Why) ->
    io:format("  nu a mers: ~p~n", [Why]),
    {error, Why}.

%% Acceptam si siruri, si binare. A tasta `<<"..."/utf8>>' de treizeci de ori
%% pe zi e exact genul de fricitiune care face o unealta sa fie nefolosita.
text(Value) when is_binary(Value) -> Value;
text(Value) when is_list(Value) -> unicode:characters_to_binary(Value).

join(Sources) -> lists:join(<<", ">>, Sources).

snippet(Text) ->
    Points = unicode:characters_to_list(Text),
    case length(Points) > 90 of
        true -> unicode:characters_to_binary(lists:sublist(Points, 90));
        false -> Text
    end.
