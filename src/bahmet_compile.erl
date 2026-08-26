%%%-------------------------------------------------------------------
%%% @doc bahmet_compile -- sursa .b27 -> module Erlang.
%%%
%%%   text -> jetoane -> AST -> INVARIANTE -> sursa Erlang
%%%
%%% Pasul cu majuscule e singurul care nu exista in majoritatea
%%% compilatoarelor. Restul traduc; acela refuza.
%%% @end
%%%-------------------------------------------------------------------
-module(bahmet_compile).

-export([string/1, file/1, to_dir/2, report/1]).

-type failure() :: {lexical, pos_integer(), string()}
                 | {syntax, pos_integer(), string()}
                 | {invariants, [bahmet_check:error()]}
                 | {cannot_read, file:filename(), term()}.

-spec string(string() | binary()) -> {ok, [{module(), binary()}]} | {error, failure()}.
string(Source) when is_binary(Source) ->
    string(unicode:characters_to_list(Source));
string(Source) ->
    case bahmet_lexer:string(Source) of
        {ok, Tokens, _Line} -> parse(Tokens);
        {error, {Line, Module, Reason}, _} ->
            {error, {lexical, Line, lists:flatten(Module:format_error(Reason))}}
    end.

parse(Tokens) ->
    case bahmet_parser:parse(Tokens) of
        {ok, Ast} -> verify(Ast);
        {error, {Line, Module, Message}} ->
            {error, {syntax, Line, lists:flatten(Module:format_error(Message))}}
    end.

%% Aici se opreste tot ce incalca GRAMMAR.md §4. Nu generam cod pentru un
%% cerc care nu-si respecta propriile trasaturi -- un compilator care emite
%% oricum, cu un avertisment, invata dezvoltatorul sa ignore avertismentele.
verify(Ast) ->
    case bahmet_check:circle(Ast) of
        ok -> {ok, bahmet_forge:circle(Ast)};
        {error, Errors} -> {error, {invariants, Errors}}
    end.

-spec file(file:filename()) -> {ok, [{module(), binary()}]} | {error, failure()}.
file(Path) ->
    case file:read_file(Path) of
        {ok, Binary} -> string(Binary);
        {error, Reason} -> {error, {cannot_read, Path, Reason}}
    end.

%% @doc Compileaza si scrie modulele .erl generate.
-spec to_dir(file:filename(), file:filename()) ->
          {ok, [file:filename()]} | {error, failure()}.
to_dir(Path, Dir) ->
    case file(Path) of
        {ok, Modules} ->
            ok = filelib:ensure_dir(filename:join(Dir, "x")),
            Written = [begin
                           Target = filename:join(Dir, atom_to_list(M) ++ ".erl"),
                           ok = file:write_file(Target, Source),
                           Target
                       end || {M, Source} <- Modules],
            {ok, Written};
        Error ->
            Error
    end.

%% @doc Mesaj citibil. Invariantele spun DE CE, nu doar unde.
-spec report(failure()) -> string().
report({lexical, Line, Text}) ->
    lists:flatten(io_lib:format("Eroare lexicala, linia ~p: ~ts~n", [Line, Text]));
report({syntax, Line, Text}) ->
    lists:flatten(io_lib:format("Eroare de sintaxa, linia ~p: ~ts~n", [Line, Text]));
report({invariants, Errors}) ->
    lists:flatten(["Cercul nu isi respecta propriile trasaturi:\n",
                   bahmet_check:format(Errors)]);
report({cannot_read, Path, Reason}) ->
    lists:flatten(io_lib:format("Nu pot citi ~ts: ~p~n", [Path, Reason])).
