%%%-------------------------------------------------------------------
%%% @doc bahmet_scribe -- Cititorul.
%%%
%%% Transforma ce ai (PDF, HTML, pagini web) in ce poate fi asimilat (text
%%% curat). Nimic mai mult: nu vectorizeaza, nu tine minte, nu raspunde.
%%%
%%% ═══════════════════════════════════════════════════════════════════
%%%  DE CE `pdftotext' SI NU O BIBLIOTECA
%%% ═══════════════════════════════════════════════════════════════════
%%%
%%% PDF nu e un format de text, e un limbaj de descriere a paginii. Un
%%% paragraf poate fi douazeci de comenzi de pozitionare a glifelor, in orice
%%% ordine, cu fonturi care isi definesc propria codificare. Bibliotecile
%%% „pure" din orice limbaj se descurca pe PDF-uri simple si esueaza tacut pe
%%% restul -- iti dau text amestecat, sau text lipsa, fara sa spuna nimic.
%%%
%%% `pdftotext' (poppler) e cod maturat de douazeci de ani pe exact aceasta
%%% problema. A-l reimplementa ar fi acelasi fel de greseala ca a scrie
%%% propriul AES: multa munca pentru un rezultat mai prost.
%%%
%%%   sudo apt-get install poppler-utils
%%%
%%% ═══════════════════════════════════════════════════════════════════
%%%  ONESTITATE DESPRE HTML
%%% ═══════════════════════════════════════════════════════════════════
%%%
%%% Curatarea de mai jos e cu expresii regulate, ceea ce e teoretic gresit --
%%% HTML nu e un limbaj regulat. Functioneaza in practica pentru articole si
%%% documentatie, si esueaza pe pagini construite din JavaScript, unde textul
%%% nici nu exista in raspunsul primit.
%%%
%%% Pentru cazul acela ai nevoie de un browser fara interfata, ceea ce e un alt
%%% ordin de complexitate. Spun asta aici ca sa nu descoperi singur, dupa ce
%%% asimilezi o pagina si primesti zero fragmente.
%%% @end
%%%-------------------------------------------------------------------
-module(bahmet_scribe).

-export([read/1, fetch/1, strip_html/1, kind/1]).

-define(FETCH_TIMEOUT, 30000).
-define(PDF_TIMEOUT, 120000).

-type failure() :: {missing_tool, string()}
                 | {cannot_read, term()}
                 | {extraction_failed, integer(), binary()}
                 | {http, integer()}
                 | {unreachable, term()}
                 | {unsupported, atom()}.

%%====================================================================
%% Citirea
%%====================================================================

%% @doc Citeste un fisier si intoarce textul lui, dupa extensie.
-spec read(file:filename()) -> {ok, binary()} | {error, failure()}.
read(Path) ->
    case kind(Path) of
        text -> plain(Path);
        pdf -> pdf(Path);
        html -> markup(Path);
        Other -> {error, {unsupported, Other}}
    end.

%% @doc Ce fel de document e, dupa extensie.
-spec kind(file:filename()) -> text | pdf | html | unknown.
kind(Path) ->
    case string:lowercase(filename:extension(Path)) of
        ".txt" -> text;
        ".md" -> text;
        ".markdown" -> text;
        ".org" -> text;
        ".rst" -> text;
        ".pdf" -> pdf;
        ".html" -> html;
        ".htm" -> html;
        ".xhtml" -> html;
        _ -> unknown
    end.

plain(Path) ->
    case file:read_file(Path) of
        {ok, Binary} -> {ok, utf8(Binary)};
        {error, Reason} -> {error, {cannot_read, Reason}}
    end.

markup(Path) ->
    case file:read_file(Path) of
        {ok, Binary} -> {ok, strip_html(utf8(Binary))};
        {error, Reason} -> {error, {cannot_read, Reason}}
    end.

%%====================================================================
%% PDF
%%====================================================================

pdf(Path) ->
    case os:find_executable("pdftotext") of
        false ->
            %% Refuz explicit, cu leacul in mesaj. Un `{error, enoent}' l-ar fi
            %% pus pe cititor sa ghiceasca ce lipseste.
            {error, {missing_tool,
                     "pdftotext nu e instalat: sudo apt-get install poppler-utils"}};
        Executable ->
            %% `-layout' pastreaza asezarea coloanelor; fara el, un PDF pe doua
            %% coloane iese amestecat rand cu rand si devine de necitit.
            Port = open_port({spawn_executable, Executable},
                             [{args, ["-q", "-layout", "-enc", "UTF-8", Path, "-"]},
                              binary, exit_status, stderr_to_stdout]),
            harvest(Port, [], ?PDF_TIMEOUT)
    end.

harvest(Port, Acc, Timeout) ->
    receive
        {Port, {data, Chunk}} ->
            harvest(Port, [Chunk | Acc], Timeout);
        {Port, {exit_status, 0}} ->
            {ok, utf8(iolist_to_binary(lists:reverse(Acc)))};
        {Port, {exit_status, Code}} ->
            {error, {extraction_failed, Code, iolist_to_binary(lists:reverse(Acc))}}
    after Timeout ->
        %% Termenul e explicit aici ca peste tot. Un PDF corupt poate bloca
        %% `pdftotext' la nesfarsit, iar o asteptare fara termen nu e rabdare.
        catch port_close(Port),
        {error, {extraction_failed, timeout, <<>>}}
    end.

%%====================================================================
%% Web
%%====================================================================

%% @doc Aduce o pagina si intoarce textul ei.
%%
%% Trimite un `User-Agent' care spune cine suntem. Nu e o formalitate: un
%% agent anonim e cel dintai blocat, iar unul care se da drept browser minte.
-spec fetch(string()) -> {ok, binary()} | {error, failure()}.
fetch(Url) ->
    _ = application:ensure_all_started(inets),
    _ = application:ensure_all_started(ssl),
    Headers = [{"User-Agent", "bahmet27/0.1 (cititor personal)"},
               {"Accept", "text/html,text/plain"}],
    case httpc:request(get, {Url, Headers},
                       [{timeout, ?FETCH_TIMEOUT}, {connect_timeout, 10000},
                        {autoredirect, true}],
                       [{body_format, binary}]) of
        {ok, {{_Version, 200, _Reason}, Received, Body}} ->
            {ok, shape(Received, Body)};
        {ok, {{_Version, Status, _Reason}, _Headers, _Body}} ->
            {error, {http, Status}};
        {error, Reason} ->
            {error, {unreachable, Reason}}
    end.

shape(Headers, Body) ->
    Type = proplists:get_value("content-type", Headers, "text/html"),
    case string:find(string:lowercase(Type), "text/plain") of
        nomatch -> strip_html(utf8(Body));
        _ -> utf8(Body)
    end.

%%====================================================================
%% HTML
%%====================================================================

%% @doc Scoate marcajele si lasa textul.
%%
%% Ordinea pasilor conteaza. `script' si `style' se scot INTAI, cu tot cu
%% continut: altfel, dupa ce cad etichetele, codul JavaScript ar ramane in
%% text si ar fi vectorizat ca si cum ar fi proza.
-spec strip_html(binary()) -> binary().
strip_html(Html) ->
    Steps = [
        {"(?is)<script[^>]*>.*?</script>", " "},
        {"(?is)<style[^>]*>.*?</style>", " "},
        {"(?is)<head[^>]*>.*?</head>", " "},
        {"(?s)<!--.*?-->", " "},
        %% Etichetele de bloc devin rand nou, ca paragrafele sa ramana
        %% distincte. Fara asta, tot documentul ar deveni o singura fraza.
        {"(?i)<(br|/p|/div|/li|/tr|/h[1-6]|/blockquote)[^>]*>", "\n"},
        {"<[^>]*>", " "}
    ],
    Stripped = lists:foldl(fun({Pattern, Replacement}, Acc) ->
                                   re:replace(Acc, Pattern, Replacement,
                                              [global, {return, binary}, unicode])
                           end, Html, Steps),
    tidy(entities(Stripped)).

entities(Text) ->
    Named = [{<<"&nbsp;">>, <<" ">>}, {<<"&#160;">>, <<" ">>},
             {<<"&lt;">>, <<"<">>}, {<<"&gt;">>, <<">">>},
             {<<"&quot;">>, <<"\"">>}, {<<"&apos;">>, <<"'">>},
             {<<"&mdash;">>, <<"—"/utf8>>}, {<<"&ndash;">>, <<"–"/utf8>>},
             {<<"&hellip;">>, <<"…"/utf8>>}, {<<"&laquo;">>, <<"«"/utf8>>},
             {<<"&raquo;">>, <<"»"/utf8>>},
             %% `&amp;' LA URMA: altfel `&amp;lt;' ar deveni `<' in loc de
             %% `&lt;'. Ordinea decodarii e o capcana clasica.
             {<<"&amp;">>, <<"&">>}],
    Decoded = lists:foldl(fun({From, To}, Acc) ->
                                  binary:replace(Acc, From, To, [global])
                          end, Text, Named),
    numeric(Decoded).

numeric(Text) ->
    case re:run(Text, "&#([0-9]{1,7});", [global, {capture, all, binary}, unicode]) of
        nomatch ->
            Text;
        {match, Matches} ->
            lists:foldl(fun([Whole, Digits], Acc) ->
                                Code = binary_to_integer(Digits),
                                case Code > 0 andalso Code =< 16#10FFFF of
                                    true ->
                                        Char = unicode:characters_to_binary([Code]),
                                        binary:replace(Acc, Whole, Char, [global]);
                                    false ->
                                        Acc
                                end
                        end, Text, Matches)
    end.

tidy(Text) ->
    Collapsed = re:replace(Text, "[ \\t]+", " ", [global, {return, binary}, unicode]),
    Trimmed = re:replace(Collapsed, "\\n{3,}", "\n\n", [global, {return, binary}, unicode]),
    string:trim(Trimmed).

%%====================================================================

%% Documentele reale nu sunt mereu UTF-8 valid -- pagini vechi, PDF-uri cu
%% fonturi ciudate, fisiere salvate in latin1. Convertim ce putem si inlocuim
%% ce nu, in loc sa aruncam tot documentul pentru un octet.
utf8(Binary) ->
    case unicode:characters_to_binary(Binary, utf8, utf8) of
        Valid when is_binary(Valid) -> Valid;
        _ -> unicode:characters_to_binary(Binary, latin1, utf8)
    end.
