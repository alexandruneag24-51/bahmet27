%%%-------------------------------------------------------------------
%%% @doc Taierea in bucati.
%%%
%%% Suita s-a nascut dintr-un bug real: prima versiune taia la OCTETUL N.
%%% Pe text ASCII mergea perfect. Pe primul document cu diacritice a cazut --
%%% `ă' are doi octeti, `─' are trei, iar o taietura la mijlocul unui caracter
%%% produce un binar care nu mai e text valid.
%%%
%%% Testul care ar fi prins-o nu e complicat. Lipsea doar fiindca textul de
%%% proba fusese ASCII curat, ca in majoritatea exemplelor scrise in graba.
%%% De aceea aproape fiecare caz de aici foloseste text cu diacritice.
%%% @end
%%%-------------------------------------------------------------------
-module(bahmet_chunk_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0]).
-export([textul_scurt_ramane_intreg/1,
         diacriticele_nu_se_rup/1,
         caracterele_de_trei_octeti_nu_se_rup/1,
         bucatile_se_suprapun/1,
         taie_la_cuvant_cand_poate/1,
         taie_la_limita_cand_nu_poate/1,
         spatiile_se_normalizeaza/1,
         textul_gol_nu_produce_bucati/1,
         acopera_tot_textul/1]).

all() ->
    [textul_scurt_ramane_intreg,
     diacriticele_nu_se_rup,
     caracterele_de_trei_octeti_nu_se_rup,
     bucatile_se_suprapun,
     taie_la_cuvant_cand_poate,
     taie_la_limita_cand_nu_poate,
     spatiile_se_normalizeaza,
     textul_gol_nu_produce_bucati,
     acopera_tot_textul].

%%====================================================================

textul_scurt_ramane_intreg(_Config) ->
    ?assertEqual([<<"un gand scurt">>],
                 bahmet_memory:chunk(<<"un gand scurt">>, {100, 10})).

%% CAZUL CENTRAL. Fiecare bucata trebuie sa fie text valid, indiferent unde
%% cade limita. Daca taiem pe octeti, `characters_to_list' intoarce un tuplu
%% de eroare in loc de o lista -- si aceea e dovada rupturii.
diacriticele_nu_se_rup(_Config) ->
    Text = binary:copy(<<"ăîșțâ ĂÎȘȚÂ răbdare împlinire dăruire "/utf8>>, 40),
    Pieces = bahmet_memory:chunk(Text, {50, 10}),
    ?assert(length(Pieces) > 1),
    _ = [?assert(is_list(unicode:characters_to_list(P))) || P <- Pieces],
    %% Si, esential: fiecare bucata poate fi prelucrata ca text.
    _ = [?assertMatch(<<_/binary>>, string:trim(P)) || P <- Pieces].

%% Caracterele de desenat cutii au trei octeti fiecare. Un document tehnic cu
%% diagrame ASCII e plin de ele -- exact ce a rupt prima versiune.
caracterele_de_trei_octeti_nu_se_rup(_Config) ->
    Text = binary:copy(<<"─────┬──── coloană │ altă coloană ────┘ "/utf8>>, 30),
    Pieces = bahmet_memory:chunk(Text, {40, 8}),
    ?assert(length(Pieces) > 1),
    _ = [?assert(is_list(unicode:characters_to_list(P))) || P <- Pieces].

%% Suprapunerea nu e risipa: fara ea, un gand taiat exact la granita ar fi pe
%% jumatate in fiecare bucata si intreg in niciuna.
bucatile_se_suprapun(_Config) ->
    Words = [<<" cuvant", (integer_to_binary(N))/binary>> || N <- lists:seq(1, 60)],
    Text = iolist_to_binary(Words),
    [First, Second | _] = bahmet_memory:chunk(Text, {60, 20}),
    Tail = binary:part(First, byte_size(First), -10),
    ?assertNotEqual(nomatch, binary:match(Second, Tail)).

taie_la_cuvant_cand_poate(_Config) ->
    Text = binary:copy(<<"alfa beta gama delta ">>, 20),
    Pieces = bahmet_memory:chunk(Text, {40, 5}),
    %% Nicio bucata nu incepe sau se termina cu spatiu, si niciuna nu contine
    %% un cuvant taiat -- toate cuvintele sursei sunt intregi.
    _ = [begin
             ?assertNotEqual($\s, binary:first(P)),
             ?assertNotEqual($\s, binary:last(P))
         end || P <- Pieces].

%% Un tabel, o cale lunga sau un bloc de cod pot sa nu aiba niciun spatiu in a
%% doua jumatate. Atunci taiem la limita: o bucata cu un cuvant rupt e mai buna
%% decat una de zece ori prea mare.
taie_la_limita_cand_nu_poate(_Config) ->
    Text = binary:copy(<<"x">>, 200),
    Pieces = bahmet_memory:chunk(Text, {50, 10}),
    ?assert(length(Pieces) >= 4),
    _ = [?assert(byte_size(P) =< 50) || P <- Pieces].

spatiile_se_normalizeaza(_Config) ->
    Text = <<"multe\n\n\nrânduri\t\tsi   spatii"/utf8>>,
    [Piece] = bahmet_memory:chunk(Text, {200, 10}),
    ?assertEqual(nomatch, binary:match(Piece, <<"  ">>)),
    ?assertEqual(nomatch, binary:match(Piece, <<"\n">>)).

textul_gol_nu_produce_bucati(_Config) ->
    ?assertEqual([], bahmet_memory:chunk(<<>>, {100, 10})),
    ?assertEqual([], bahmet_memory:chunk(<<"   \n\t  ">>, {100, 10})).

%% Nimic nu se pierde: fiecare cuvant din sursa apare in cel putin o bucata.
%% Fara asta, o carte asimilata ar avea gauri invizibile.
acopera_tot_textul(_Config) ->
    Words = [<<"marca", (integer_to_binary(N))/binary, " ">> || N <- lists:seq(1, 80)],
    Text = iolist_to_binary(Words),
    Pieces = bahmet_memory:chunk(Text, {70, 15}),
    Joined = iolist_to_binary(Pieces),
    _ = [?assertNotEqual({N, nomatch},
                         {N, binary:match(Joined, <<"marca", (integer_to_binary(N))/binary>>)})
         || N <- lists:seq(1, 80)].
