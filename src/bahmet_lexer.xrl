%%%-------------------------------------------------------------------
%%% Bahmet 27 -- analizorul lexical (leex).
%%%
%%% Subsetul Fazei 3: `circle', `ground', `commons', `being' cu `carries',
%%% atribute si clauze. Restul gramaticii din dsl/GRAMMAR.md urmeaza.
%%%
%%% Cuvintele-cheie sunt scumpe intr-un limbaj mic: fiecare cuvant rezervat
%%% e un nume pe care dezvoltatorul nu-l mai poate folosi. De aceea
%%% `dimension' si `seed' NU sunt cuvinte-cheie -- ar fi facut imposibil
%%% `upon offering(seed : tensor[256])'. Sunt perechi cheie-valoare
%%% obisnuite, validate de bahmet_check.
%%%-------------------------------------------------------------------

Definitions.

LOWER      = [a-z]
UPPER      = [A-Z]
ALNUM      = [a-zA-Z0-9_]
DIGIT      = [0-9]
WHITESPACE = [\s\t\n\r]
COMMENT    = #[^\n\r]*

Rules.

{COMMENT}                            : skip_token.
{WHITESPACE}+                        : skip_token.

{DIGIT}+(ms|s|m)                     : {token, {duration, TokenLine, duration(TokenChars)}}.
{DIGIT}+\.{DIGIT}+                   : {token, {float, TokenLine, list_to_float(TokenChars)}}.
{DIGIT}+                             : {token, {int, TokenLine, list_to_integer(TokenChars)}}.

{UPPER}{ALNUM}*(\.{UPPER}{ALNUM}*)*  : {token, {name, TokenLine, unicode:characters_to_binary(TokenChars)}}.
{LOWER}{ALNUM}*                      : classify(TokenChars, TokenLine).

"[^"]*"                              : {token, {string, TokenLine, unquote(TokenChars)}}.

<-                                   : {token, {'<-', TokenLine}}.
->                                   : {token, {'->', TokenLine}}.
:                                    : {token, {':', TokenLine}}.
,                                    : {token, {',', TokenLine}}.
\(                                   : {token, {'(', TokenLine}}.
\)                                   : {token, {')', TokenLine}}.
\[                                   : {token, {'[', TokenLine}}.
\]                                   : {token, {']', TokenLine}}.
=                                    : {token, {'=', TokenLine}}.
\+                                   : {token, {'+', TokenLine}}.

Erlang code.

-export([keywords/0]).

%% Douazeci si sase de cuvinte. Fiecare a trebuit sa-si justifice locul.
keywords() ->
    ['circle', 'being', 'carries', 'end',
     'patience', 'grace',
     'awaken', 'with', 'upon', 'from',
     'keep', 'completion', 'merging', 'into',
     'release', 'quietly', 'giving', 'withholding',
     'when', 'broken',
     'offer', 'to', 'intuit',
     'commons', 'ground',
     'text', 'count', 'tensor', 'void'].

classify(Chars, Line) ->
    %% `list_to_atom' pe intrare arbitrara ar fi o scurgere in tabela de
    %% atomi. Aici e acceptabil: intrarea unui compilator e cod scris de
    %% dezvoltator, nu date venite de la un atacator. Distinctia conteaza --
    %% acelasi apel in bahmet_council_sup ar fi fost o greseala.
    Atom = list_to_atom(Chars),
    case lists:member(Atom, keywords()) of
        true  -> {token, {Atom, Line}};
        false -> {token, {ident, Line, Atom}}
    end.

%% Duratele devin milisecunde chiar in lexer. `30s' nu e „treizeci urmat de
%% s", e o valoare de timp -- iar restul compilatorului nu trebuie sa mai
%% stie ca a existat vreodata o unitate.
duration(Chars) ->
    case lists:reverse(Chars) of
        [$s, $m | Rest] -> list_to_integer(lists:reverse(Rest));
        [$s | Rest]     -> list_to_integer(lists:reverse(Rest)) * 1000;
        [$m | Rest]     -> list_to_integer(lists:reverse(Rest)) * 60000
    end.

unquote(Chars) ->
    unicode:characters_to_binary(lists:sublist(Chars, 2, length(Chars) - 2)).
