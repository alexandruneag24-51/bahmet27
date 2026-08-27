%%%-------------------------------------------------------------------
%%% @doc Cititorul.
%%%
%%% Curatarea HTML e cu expresii regulate, ceea ce e teoretic gresit -- HTML nu
%%% e un limbaj regulat. Functioneaza in practica pentru articole si
%%% documentatie, iar cazurile de aici marcheaza exact unde se opreste
%%% „practica".
%%%
%%% Cazurile cu `script' si cu ordinea entitatilor sunt cele care conteaza:
%%% amandoua sunt greseli pe care le face aproape oricine scrie un curatitor
%%% de HTML pentru prima oara.
%%% @end
%%%-------------------------------------------------------------------
-module(bahmet_scribe_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0]).
-export([recunoaste_tipul_dupa_extensie/1,
         etichetele_dispar/1,
         scriptul_dispare_cu_tot_cu_continut/1,
         stilul_dispare_cu_tot_cu_continut/1,
         blocurile_devin_randuri/1,
         entitatile_se_decodeaza/1,
         ordinea_entitatilor_e_corecta/1,
         entitatile_numerice_se_decodeaza/1,
         diacriticele_supravietuiesc/1,
         spatiile_se_string/1,
         citeste_text_de_pe_disc/1,
         refuza_ce_nu_stie/1]).

all() ->
    [recunoaste_tipul_dupa_extensie,
     etichetele_dispar,
     scriptul_dispare_cu_tot_cu_continut,
     stilul_dispare_cu_tot_cu_continut,
     blocurile_devin_randuri,
     entitatile_se_decodeaza,
     ordinea_entitatilor_e_corecta,
     entitatile_numerice_se_decodeaza,
     diacriticele_supravietuiesc,
     spatiile_se_string,
     citeste_text_de_pe_disc,
     refuza_ce_nu_stie].

%%====================================================================

recunoaste_tipul_dupa_extensie(_Config) ->
    ?assertEqual(text, bahmet_scribe:kind("carte.txt")),
    ?assertEqual(text, bahmet_scribe:kind("NOTE.MD")),
    ?assertEqual(pdf, bahmet_scribe:kind("/cale/lunga/lucrare.pdf")),
    ?assertEqual(html, bahmet_scribe:kind("pagina.html")),
    ?assertEqual(html, bahmet_scribe:kind("pagina.htm")),
    ?assertEqual(unknown, bahmet_scribe:kind("arhiva.zip")).

etichetele_dispar(_Config) ->
    Clean = bahmet_scribe:strip_html(<<"<p>text <b>ingrosat</b> si <i>inclinat</i></p>">>),
    ?assertEqual(nomatch, binary:match(Clean, <<"<">>)),
    ?assertNotEqual(nomatch, binary:match(Clean, <<"ingrosat">>)),
    ?assertNotEqual(nomatch, binary:match(Clean, <<"inclinat">>)).

%% GRESEALA CLASICA. Daca scoti intai etichetele si abia apoi te gandesti la
%% `script', codul JavaScript ramane in text si ajunge sa fie vectorizat ca si
%% cum ar fi proza. Raspunsurile devin subtil mai proaste, fara nicio eroare.
scriptul_dispare_cu_tot_cu_continut(_Config) ->
    Html = <<"<p>inceput</p><script>var x = 1; alert('bau');</script><p>sfarsit</p>">>,
    Clean = bahmet_scribe:strip_html(Html),
    ?assertEqual(nomatch, binary:match(Clean, <<"alert">>)),
    ?assertEqual(nomatch, binary:match(Clean, <<"var x">>)),
    ?assertNotEqual(nomatch, binary:match(Clean, <<"inceput">>)),
    ?assertNotEqual(nomatch, binary:match(Clean, <<"sfarsit">>)).

stilul_dispare_cu_tot_cu_continut(_Config) ->
    Html = <<"<style>body { color: red; }</style><p>continut</p>">>,
    Clean = bahmet_scribe:strip_html(Html),
    ?assertEqual(nomatch, binary:match(Clean, <<"color">>)),
    ?assertNotEqual(nomatch, binary:match(Clean, <<"continut">>)).

%% Fara asta, tot documentul devine o singura fraza, iar taierea in bucati nu
%% mai are unde sa cada natural.
blocurile_devin_randuri(_Config) ->
    Clean = bahmet_scribe:strip_html(<<"<p>unu</p><p>doi</p><li>trei</li>">>),
    ?assertNotEqual(nomatch, binary:match(Clean, <<"\n">>)).

entitatile_se_decodeaza(_Config) ->
    Clean = bahmet_scribe:strip_html(<<"a &lt; b &gt; c &quot;citat&quot; &nbsp; final">>),
    ?assertNotEqual(nomatch, binary:match(Clean, <<"a < b > c">>)),
    ?assertNotEqual(nomatch, binary:match(Clean, <<"\"citat\"">>)),
    ?assertEqual(nomatch, binary:match(Clean, <<"&">>)).

%% A DOUA GRESEALA CLASICA. Daca decodezi `&amp;' primul, atunci `&amp;lt;'
%% devine `&lt;' si apoi `<' -- adica textul scapa din propria codificare.
%% Ordinea nu e stilistica.
ordinea_entitatilor_e_corecta(_Config) ->
    Clean = bahmet_scribe:strip_html(<<"scrie &amp;lt; ca sa arate un semn">>),
    ?assertNotEqual(nomatch, binary:match(Clean, <<"&lt;">>)),
    ?assertEqual(nomatch, binary:match(Clean, <<"&amp;">>)).

entitatile_numerice_se_decodeaza(_Config) ->
    Clean = bahmet_scribe:strip_html(<<"punct &#8230; si apostrof &#39;">>),
    ?assertNotEqual(nomatch, binary:match(Clean, <<"…"/utf8>>)),
    ?assertNotEqual(nomatch, binary:match(Clean, <<"'">>)).

%% Aceeasi lectie ca la taierea in bucati: textul real are diacritice, iar
%% exemplele scrise in graba nu au. Fiecare pas trebuie sa le pastreze.
diacriticele_supravietuiesc(_Config) ->
    Html = <<"<p>răbdarea și împlinirea, cu ăîșțâ</p>"/utf8>>,
    Clean = bahmet_scribe:strip_html(Html),
    ?assertNotEqual(nomatch, binary:match(Clean, <<"răbdarea"/utf8>>)),
    ?assertNotEqual(nomatch, binary:match(Clean, <<"ăîșțâ"/utf8>>)),
    ?assert(is_list(unicode:characters_to_list(Clean))).

spatiile_se_string(_Config) ->
    Clean = bahmet_scribe:strip_html(<<"<p>multe     spatii</p>\n\n\n\n<p>si randuri</p>">>),
    ?assertEqual(nomatch, binary:match(Clean, <<"    ">>)),
    ?assertEqual(nomatch, binary:match(Clean, <<"\n\n\n">>)).

citeste_text_de_pe_disc(Config) ->
    Dir = proplists:get_value(priv_dir, Config),
    Path = filename:join(Dir, "proba.md"),
    ok = file:write_file(Path, <<"# Titlu\n\nUn gând cu diacritice."/utf8>>),
    {ok, Text} = bahmet_scribe:read(Path),
    ?assertNotEqual(nomatch, binary:match(Text, <<"diacritice"/utf8>>)).

refuza_ce_nu_stie(Config) ->
    Dir = proplists:get_value(priv_dir, Config),
    Path = filename:join(Dir, "ceva.zip"),
    ok = file:write_file(Path, <<"PK">>),
    ?assertEqual({error, {unsupported, unknown}}, bahmet_scribe:read(Path)).
