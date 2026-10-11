%%%-------------------------------------------------------------------
%%% @doc Codurile: memoria comprimata si chipul ei cistercian, prin NIF.
%%%
%%% Matematica e probata in Rust (`cargo test'); aici probam puntea: ca
%%% Erlang primeste ce declara spec-urile, si ca erorile vin ca valori.
%%% @end
%%%-------------------------------------------------------------------
-module(bahmet_codes_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0]).
-export([comprimarea_isi_gaseste_amintirea/1,
         codul_are_patru_parti_mici/1,
         mai_multe_forme_decat_amintiri_e_refuzat/1,
         chipul_e_svg/1,
         peste_9999_nu_are_chip/1]).

all() ->
    [comprimarea_isi_gaseste_amintirea,
     codul_are_patru_parti_mici,
     mai_multe_forme_decat_amintiri_e_refuzat,
     chipul_e_svg,
     peste_9999_nu_are_chip].

%%====================================================================

comprimarea_isi_gaseste_amintirea(_Config) ->
    {Memory, Vectors} = memory(64, 8),
    Coded = bahmet_recall:compress(Memory, 4, 64),
    ?assertMatch(#{parts := 4, centroids := 64, remembered := 64},
                 bahmet_recall:coded_status(Coded)),
    [{Id, _} | _] = bahmet_recall:recall_coded(Coded, lists:nth(10, Vectors), 3),
    ?assertEqual(10, Id),
    ?assertEqual({error, dimension_discord}, bahmet_recall:recall_coded(Coded, [1.0], 3)).

codul_are_patru_parti_mici(_Config) ->
    {Memory, _} = memory(300, 16),
    Coded = bahmet_recall:compress(Memory, 4, 16),
    Code = bahmet_recall:code_of(Coded, 7),
    ?assertEqual(4, length(Code)),
    ?assert(lists:all(fun(C) -> C >= 0 andalso C < 16 end, Code)),
    ?assertEqual({error, not_found}, bahmet_recall:code_of(Coded, 99999)),
    #{bytes := Bytes, full_bytes := Full} = bahmet_recall:coded_status(Coded),
    ?assertEqual(300 * 16 * 4, Full),
    ?assertEqual(300 * 4 + 4 * 16 * 4 * 4, Bytes).

mai_multe_forme_decat_amintiri_e_refuzat(_Config) ->
    {Memory, _} = memory(10, 8),
    ?assertEqual({error, unbounded_memory}, bahmet_recall:compress(Memory, 2, 256)),
    ?assertEqual({error, dimension_discord}, bahmet_recall:compress(Memory, 3, 2)).

chipul_e_svg(_Config) ->
    Svg = bahmet_recall:glyph([17, 203, 5, 9999]),
    ?assertMatch(<<"<svg", _/binary>>, Svg),
    ?assertEqual(4, length(binary:matches(Svg, <<"<path">>))).

peste_9999_nu_are_chip(_Config) ->
    ?assertEqual({error, not_representable}, bahmet_recall:glyph([1, 10000, 3, 4])).

%%====================================================================

%% `N' vectori aleatori de dimensiune `Dim', cu identitatile 1..N.
memory(N, Dim) ->
    rand:seed(exsss, {27, 10, 2026}),
    Memory = bahmet_recall:open_memory(Dim),
    Vectors = [[rand:uniform() - 0.5 || _ <- lists:seq(1, Dim)] || _ <- lists:seq(1, N)],
    _ = [ok = bahmet_recall:remember(Memory, I, V)
         || {I, V} <- lists:zip(lists:seq(1, N), Vectors)],
    {Memory, Vectors}.
