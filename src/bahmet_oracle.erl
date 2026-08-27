%%%-------------------------------------------------------------------
%%% @doc bahmet_oracle -- Vorbirea cu lumea.
%%%
%%% ═══════════════════════════════════════════════════════════════════
%%%  DE CE HTTP-UL E AICI SI NU IN RUST
%%% ═══════════════════════════════════════════════════════════════════
%%%
%%% Tentatia era sa punem cererea catre Ollama intr-un NIF. Ar fi fost o
%%% greseala tehnica si o tradare a impartirii pe care sta tot proiectul.
%%%
%%% Tehnic: o inferenta dureaza 5-60 de secunde. Un NIF, chiar pe planificator
%%% murdar, ar tine ocupat un fir dintr-un bazin limitat (implicit, numarul de
%%% nuclee) pe toata durata. Patru cereri simultane ar infometa tot bazinul --
%%% inclusiv criptografia, care il imparte. Si nu ai cum sa anulezi.
%%%
%%% Filozofic: Focul vorbeste cu lumea, Apa gandeste in tacere. Un Rust care
%%% face cereri HTTP ar fi Apa iesita la suprafata sa dea telefoane. Erlang e
%%% construit exact pentru asta: procese ieftine, fiecare cu termenul lui,
%%% niciunul blocand pe altul.
%%%
%%% ═══════════════════════════════════════════════════════════════════
%%%  O FIINTA IN INFERENTA E O FIINTA SURDA
%%% ═══════════════════════════════════════════════════════════════════
%%%
%%% Cat timp un gen_server asteapta raspunsul, nu-si citeste cutia postala.
%%% Nu e un bug -- mesajele se aduna si vor fi prelucrate dupa -- dar e o
%%% alegere de proiectare care trebuie stiuta: o fiinta coborata in Adanc nu
%%% aude `calling_home' pana nu se intoarce.
%%%
%%% De aceea `patience' unei fiinte care cheama oracolul trebuie sa fie mai
%%% mare decat `?DEEP_TIMEOUT'. Altfel ai declarat o rabdare pe care sistemul
%%% nu o poate respecta.
%%% @end
%%%-------------------------------------------------------------------
-module(bahmet_oracle).

-export([ask/1, ask/2,
         see/2, see/3,
         embed/1, embed/2,
         health/0,
         dimension/0]).

%% Termenele sunt explicite peste tot, ca in restul limbajului. O asteptare
%% fara termen nu e rabdare, e blocaj.
-define(CONNECT_TIMEOUT, 5000).
-define(DEEP_TIMEOUT, 120000).   %% raspuns de la un model de viziune
-define(EMBED_TIMEOUT, 30000).   %% vectorizarea e mult mai ieftina

-type failure() :: {unreachable, term()}
                 | {refused, integer(), binary()}
                 | {malformed, term()}.

%%====================================================================
%% Coborarea in Adanc
%%====================================================================

%% @doc Intrebare in text. Intoarce raspunsul modelului.
-spec ask(binary()) -> {ok, binary()} | {error, failure()}.
ask(Prompt) -> ask(Prompt, #{}).

-spec ask(binary(), map()) -> {ok, binary()} | {error, failure()}.
ask(Prompt, Options) ->
    Payload = #{
        <<"model">> => maps:get(model, Options, text_model()),
        <<"prompt">> => Prompt,
        %% `stream => false': vrem un raspuns intreg, nu o secventa de bucati.
        %% Fluxul are sens intr-o interfata; intr-un actor care oricum asteapta,
        %% ar adauga complexitate fara sa scurteze nimic.
        <<"stream">> => false
    },
    Full = maps:merge(Payload, extra(Options)),
    case request("/api/generate", Full, ?DEEP_TIMEOUT) of
        {ok, #{<<"response">> := Response}} -> {ok, Response};
        {ok, Other} -> {error, {malformed, Other}};
        {error, Why} -> {error, Why}
    end.

%% @doc Intrebare despre o imagine. `Image' sunt octetii bruti (PNG/JPEG).
%%
%% Modelul de viziune primeste imaginea in base64 -- singura forma prin care
%% un JSON poate purta octeti bruti. Conversia se face aici, la frontiera, ca
%% restul sistemului sa lucreze cu binare, nu cu text codificat.
-spec see(binary(), binary()) -> {ok, binary()} | {error, failure()}.
see(Prompt, Image) -> see(Prompt, Image, #{}).

-spec see(binary(), binary(), map()) -> {ok, binary()} | {error, failure()}.
see(Prompt, Image, Options) when is_binary(Image) ->
    Payload = #{
        <<"model">> => maps:get(model, Options, vision_model()),
        <<"prompt">> => Prompt,
        <<"images">> => [base64:encode(Image)],
        <<"stream">> => false
    },
    Full = maps:merge(Payload, extra(Options)),
    case request("/api/generate", Full, ?DEEP_TIMEOUT) of
        {ok, #{<<"response">> := Response}} -> {ok, Response};
        {ok, Other} -> {error, {malformed, Other}};
        {error, Why} -> {error, Why}
    end.

%%====================================================================
%% Vectorizarea
%%====================================================================

%% @doc Text -> vector. Pe GPU, prin acelasi Ollama.
%%
%% Am cantarit `candle' cu un model incarcat in Rust. Ar fi insemnat un
%% tokenizer reimplementat, greutati de descarcat si gestionat, si o a doua
%% cale prin care lucrurile pot merge prost -- pentru un rezultat identic.
%% Ollama ruleaza deja pe placa; ii cerem si asta.
%%
%% Valoarea lui Rust in RAG nu e vectorizarea, e CAUTAREA. Vezi bahmet_recall.
-spec embed(binary()) -> {ok, [float()]} | {error, failure()}.
embed(Text) -> embed(Text, #{}).

-spec embed(binary(), map()) -> {ok, [float()]} | {error, failure()}.
embed(Text, Options) ->
    Payload = #{
        <<"model">> => maps:get(model, Options, embed_model()),
        <<"input">> => Text
    },
    case request("/api/embed", Payload, ?EMBED_TIMEOUT) of
        {ok, #{<<"embeddings">> := [Vector | _]}} ->
            {ok, Vector};
        %% Versiunile mai vechi de Ollama expun `/api/embeddings' (plural in
        %% cale, singular in raspuns). Incercam si acolo inainte sa renuntam.
        {error, {refused, 404, _}} ->
            legacy_embed(Text, Payload);
        {ok, Other} ->
            {error, {malformed, Other}};
        {error, Why} ->
            {error, Why}
    end.

legacy_embed(Text, #{<<"model">> := Model}) ->
    Payload = #{<<"model">> => Model, <<"prompt">> => Text},
    case request("/api/embeddings", Payload, ?EMBED_TIMEOUT) of
        {ok, #{<<"embedding">> := Vector}} -> {ok, Vector};
        {ok, Other} -> {error, {malformed, Other}};
        {error, Why} -> {error, Why}
    end.

%%====================================================================
%% Sanatatea temeliei
%%====================================================================

%% @doc Oracolul raspunde? Acelasi principiu ca la `bahmet_entropy': verificam
%% temelia la pornire, nu la prima cerere reala.
-spec health() -> {ok, [binary()]} | {error, failure()}.
health() ->
    case get_request("/api/tags", ?CONNECT_TIMEOUT) of
        {ok, #{<<"models">> := Models}} ->
            {ok, [Name || #{<<"name">> := Name} <- Models]};
        {ok, Other} -> {error, {malformed, Other}};
        {error, Why} -> {error, Why}
    end.

%% @doc Dimensiunea vectorilor modelului de embedding.
%%
%% NU o presupunem -- o masuram, o data, vectorizand un cuvant. Un sistem care
%% presupune 768 si primeste 1024 nu esueaza zgomotos: umple memoria cu vectori
%% de forma gresita si returneaza vecini absurzi, luni la rand.
-spec dimension() -> {ok, pos_integer()} | {error, failure()}.
dimension() ->
    case embed(<<"masura">>) of
        {ok, Vector} -> {ok, length(Vector)};
        {error, Why} -> {error, Why}
    end.

%%====================================================================
%% Intern
%%====================================================================

request(Path, Payload, Timeout) ->
    ensure_inets(),
    Body = iolist_to_binary(json:encode(Payload)),
    Request = {url(Path), [], "application/json", Body},
    handle(httpc:request(post, Request,
                         [{timeout, Timeout}, {connect_timeout, ?CONNECT_TIMEOUT}],
                         [{body_format, binary}])).

get_request(Path, Timeout) ->
    ensure_inets(),
    handle(httpc:request(get, {url(Path), []},
                         [{timeout, Timeout}, {connect_timeout, ?CONNECT_TIMEOUT}],
                         [{body_format, binary}])).

handle({ok, {{_Version, 200, _Reason}, _Headers, Body}}) ->
    try
        {ok, json:decode(Body)}
    catch
        _:_ -> {error, {malformed, Body}}
    end;
handle({ok, {{_Version, Status, _Reason}, _Headers, Body}}) ->
    %% Un refuz al oracolului nu e o catastrofa a sistemului. E o valoare
    %% intoarsa, exact ca `decrypt_failed' din seif: apelantul decide.
    {error, {refused, Status, Body}};
handle({error, Reason}) ->
    {error, {unreachable, Reason}}.

ensure_inets() ->
    case whereis(httpc_manager) of
        undefined -> _ = application:ensure_all_started(inets), ok;
        _ -> ok
    end.

url(Path) -> base() ++ Path.

base() -> application:get_env(bahmet, ollama_url, "http://localhost:11434").
text_model() -> application:get_env(bahmet, text_model, <<"llama3.1:8b">>).
vision_model() -> application:get_env(bahmet, vision_model, <<"llava:7b">>).
embed_model() -> application:get_env(bahmet, embed_model, <<"nomic-embed-text">>).

%% Optiunile de esantionare trec neatinse catre Ollama. `temperature => 0'
%% pentru raspunsuri reproductibile in teste; implicitul modelului altfel.
extra(Options) ->
    case maps:get(options, Options, undefined) of
        undefined -> #{};
        Map -> #{<<"options">> => Map}
    end.
