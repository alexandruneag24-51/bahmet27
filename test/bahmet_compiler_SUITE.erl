%%%-------------------------------------------------------------------
%%% @doc Compilatorul.
%%%
%%% Doua feluri de cazuri, si al doilea e cel care conteaza:
%%%
%%%   ce ACCEPTA -- hearth.b27 devine un modul care compileaza si chiar
%%%   traieste sub BEAM, cu aceleasi trasaturi ca modulele scrise de mana.
%%%
%%%   ce REFUZA  -- fiecare regula din GRAMMAR.md §4 are un caz care ii
%%%   demonstreaza dintii. Un verificator netestat pe intrari INVALIDE nu e
%%%   un verificator, e o decoratiune.
%%% @end
%%%-------------------------------------------------------------------
-module(bahmet_compiler_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([lexes_keywords_and_durations/1,
         parses_hearth/1,
         generated_module_compiles/1,
         generated_being_completes_and_gives/1,
         generated_being_withholds_when_broken/1,
         generated_status_is_redacted/1,
         broken_clause_body_is_honoured/1,
         grace_survives_into_attributes/1,
         parses_contemplation/1,
         ask_without_within_is_unrepresentable/1,
         communion_preserves_tend_order/1,
         gathering_completes_when_all_do/1,
         generated_circle_compiles/1,
         generated_circle_lives/1,
         rejects_birth_outside_gathering/1,
         rejects_unreachable_being/1,
         rejects_tending_a_being/1,
         rejects_unknown_harmony/1,
         rejects_unknown_completion_rule/1,
         rejects_answer_in_upon/1,
         rejects_keep_in_rite/1,
         rejects_missing_broken_clause/1,
         rejects_missing_patience/1,
         rejects_unknown_commons/1,
         rejects_unknown_ground/1,
         rejects_bind_outside_carries/1,
         rejects_unknown_variable/1,
         rejects_duplicate_message/1,
         rejects_incomplete_ground/1,
         reports_syntax_error_with_line/1]).

all() ->
    [{group, front}, {group, refuses}, {group, generates}].

groups() ->
    [{front, [parallel], [lexes_keywords_and_durations, parses_hearth,
                          parses_contemplation, reports_syntax_error_with_line,
                          ask_without_within_is_unrepresentable]},
     {refuses, [parallel], [rejects_missing_broken_clause,
                            rejects_missing_patience,
                            rejects_unknown_commons,
                            rejects_unknown_ground,
                            rejects_bind_outside_carries,
                            rejects_unknown_variable,
                            rejects_duplicate_message,
                            rejects_incomplete_ground,
                            rejects_birth_outside_gathering,
                            rejects_unreachable_being,
                            rejects_tending_a_being,
                            rejects_unknown_harmony,
                            rejects_unknown_completion_rule,
                            rejects_answer_in_upon,
                            rejects_keep_in_rite]},
     {generates, [], [generated_module_compiles,
                      generated_being_completes_and_gives,
                      generated_being_withholds_when_broken,
                      generated_status_is_redacted,
                      broken_clause_body_is_honoured,
                      grace_survives_into_attributes,
                      communion_preserves_tend_order,
                      gathering_completes_when_all_do,
                      generated_circle_compiles,
                      %% Ultimul: opreste aplicatia si porneste cercul generat.
                      generated_circle_lives]}].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(bahmet),
    Config.

end_per_suite(_Config) ->
    _ = application:stop(bahmet),
    ok.

%%====================================================================
%% Fata compilatorului
%%====================================================================

lexes_keywords_and_durations(_Config) ->
    {ok, Tokens, _} = bahmet_lexer:string("being Keeper patience 30s grace 500ms x 2m"),
    ?assertMatch([{'being', _}, {name, _, <<"Keeper">>},
                  {'patience', _}, {duration, _, 30000},
                  {'grace', _}, {duration, _, 500},
                  {ident, _, x}, {duration, _, 120000}], Tokens),
    %% `seed' NU e cuvant-cheie: altfel `offering(seed : ...)' ar fi imposibil.
    {ok, [{ident, _, seed}], _} = bahmet_lexer:string("seed"),
    %% Comentariile dispar inainte de parser.
    {ok, [{'keep', _}], _} = bahmet_lexer:string("# doar un gand\nkeep").

parses_hearth(_Config) ->
    {ok, Modules} = bahmet_compile:file(source()),
    ?assertEqual([hearth_keeper, hearth_circle_sup, hearth_home_sup, hearth_rites],
                 [M || {M, _} <- Modules]).

reports_syntax_error_with_line(_Config) ->
    Broken = "circle Hearth\n"
             "  commons wisdom : tensor[256]\n"
             "  being Keeper\n"
             "    carries question : text end\n"
             "    patience 30s\n"
             "    upon calling_home ->\n"
             "  end\n"
             "end\n",
    ?assertMatch({error, {syntax, _, _}}, bahmet_compile:string(Broken)),
    {error, Failure} = bahmet_compile:string(Broken),
    ?assert(string:find(bahmet_compile:report(Failure), "sintaxa") =/= nomatch).

%%====================================================================
%% Ce refuza -- fiecare regula din GRAMMAR.md §4
%%====================================================================

%% Nu impunem un raspuns anume la ruptura, impunem ca autorul sa fi DECIS.
rejects_missing_broken_clause(_Config) ->
    ?assert(refuses(without("when broken ->\n      release withholding insight\n    end"),
                    "when broken")).

rejects_missing_patience(_Config) ->
    ?assert(refuses(without("patience 30s"), "patience")).

rejects_unknown_commons(_Config) ->
    ?assert(refuses(replace("into wisdom", "into nimeni"), "darui cuiva anume")).

rejects_unknown_ground(_Config) ->
    ?assert(refuses(replace("intuit deep with", "intuit adanc with"), "pamant")).

%% Forma verificabila a regulii „starea unei fiinte e inchisa". Fara ea, un
%% typo ar crea tacut un camp fantoma pe care nimeni nu-l citeste vreodata.
rejects_bind_outside_carries(_Config) ->
    ?assert(refuses(replace("insight   <- intuit", "insigt   <- intuit"), "carries")).

rejects_unknown_variable(_Config) ->
    ?assert(refuses(replace("intuit deep with gift", "intuit deep with darul"),
                    "parametru primit")).

rejects_duplicate_message(_Config) ->
    Doubled = replace("upon silence ->",
                      "upon calling_home ->\n      keep\n    end\n\n    upon silence ->"),
    ?assert(refuses(Doubled, "mai multe clauze")).

rejects_incomplete_ground(_Config) ->
    ?assert(refuses(without("seed      27"), "samanta")).

%%====================================================================
%% Ce genereaza
%%====================================================================

generated_module_compiles(Config) ->
    Dir = proplists:get_value(priv_dir, Config),
    {ok, Files} = bahmet_compile:to_dir(source(), Dir),
    %% `warnings_as_errors': cod generat cu avertismente e cod generat prost.
    _ = [?assertMatch({ok, _}, compile:file(F, [return_errors, warnings_as_errors,
                                                {outdir, Dir}, report]))
         || F <- Files],
    true = code:add_patha(Dir),
    {module, hearth_keeper} = code:load_file(hearth_keeper).

%% Bucla completa: fiinta generata primeste o ofranda, coboara in Adanc prin
%% NIF-ul Rust, se implineste si daruieste bunului comun -- exact ca fratele
%% ei scris de mana.
generated_being_completes_and_gives(Config) ->
    ok = ensure_loaded(Config),
    Before = length(bahmet_commons:contributors()),
    {ok, Pid} = hearth_keeper:start_link({generat, 1}, [<<"ce inseamna a completa">>]),
    unlink(Pid),
    ok = hearth_keeper:offering(Pid, seed()),
    timer:sleep(200),
    ok = hearth_keeper:calling_home(Pid),
    ok = wait_gone(Pid),
    timer:sleep(150),
    ?assertEqual(Before + 1, length(bahmet_commons:contributors())).

%% Clauza `when broken' se traduce in ultima clauza din `terminate/2', iar
%% ordinea nu poate fi incurcata fiindca nu o scrie un om.
generated_being_withholds_when_broken(Config) ->
    ok = ensure_loaded(Config),
    Before = length(bahmet_commons:contributors()),
    {ok, Pid} = hearth_keeper:start_link({generat, 2}, [<<"proba">>]),
    unlink(Pid),
    ok = hearth_keeper:offering(Pid, seed()),
    timer:sleep(200),
    exit(Pid, ruptura),
    ok = wait_gone(Pid),
    timer:sleep(150),
    ?assertEqual(Before, length(bahmet_commons:contributors())).

%% Compilatorul stie care camp e pretios -- e cel daruit la `completion' --
%% deci stie si care nu are voie sa apara in jurnale. Nimeni nu a scris asta.
generated_status_is_redacted(Config) ->
    ok = ensure_loaded(Config),
    {ok, Pid} = hearth_keeper:start_link({generat, 3}, [<<"q">>]),
    unlink(Pid),
    ok = hearth_keeper:offering(Pid, seed()),
    timer:sleep(200),
    {status, _Pid, _Mod, Items} = sys:get_status(Pid),
    Text = lists:flatten(io_lib:format("~p", [Items])),
    ?assertNotEqual(nomatch, string:find(Text, "redacted")),
    exit(Pid, kill).

%% Contra-proba pentru `generated_being_withholds_when_broken'.
%%
%% Retinerea la ruptura e IMPLICITUL, nu singura optiune. Daca autorul cere
%% explicit sa se daruiasca si asa, compilatorul trebuie sa-l asculte.
%%
%% Verificatorul cere ca decizia sa fie luata; ar fi mai rau decat sa nu
%% intrebe daca apoi ar ignora raspunsul.
broken_clause_body_is_honoured(Config) ->
    Dir = proplists:get_value(priv_dir, Config),
    Source = variant([{"circle Hearth", "circle Hearth.Giving"},
                      {"release withholding insight", "release quietly giving insight"}]),
    {ok, Modules} = bahmet_compile:string(Source),
    Module = hearth_giving_keeper,
    {Module, Code} = lists:keyfind(Module, 1, Modules),

    File = filename:join(Dir, atom_to_list(Module) ++ ".erl"),
    ok = file:write_file(File, Code),
    {ok, Module} = compile:file(File, [return_errors, warnings_as_errors, {outdir, Dir}]),
    true = code:add_patha(Dir),
    {module, Module} = code:load_file(Module),

    Before = length(bahmet_commons:contributors()),
    {ok, Pid} = Module:start_link({generat, 4}, [<<"q">>]),
    unlink(Pid),
    ok = Module:offering(Pid, seed()),
    timer:sleep(200),
    exit(Pid, ruptura),
    ok = wait_gone(Pid),
    timer:sleep(150),
    ?assertEqual(Before + 1, length(bahmet_commons:contributors())).

%% `grace' nu are unde ajunge in subsetul Fazei 3 -- e `shutdown' din
%% specificatia de copil, iar `communion' nu e inca in gramatica. Il pastram
%% ca atribut de modul: o declaratie care dispare tacut erodeaza increderea
%% in toate celelalte.
grace_survives_into_attributes(Config) ->
    ok = ensure_loaded(Config),
    Attributes = hearth_keeper:module_info(attributes),
    ?assertEqual([5000], proplists:get_value(bahmet_grace, Attributes)).

%%====================================================================
%% Cercul complet
%%====================================================================

parses_contemplation(_Config) ->
    {ok, Modules} = bahmet_compile:file(contemplation()),
    ?assertEqual([council_dawn_contemplator, council_dawn_gathering_sup,
                  council_dawn_council_sup, council_dawn_rites],
                 [M || {M, _} <- Modules]).

%% CAZUL CENTRAL AL FAZEI 4.
%%
%% O cerere sincrona fara `within' nu e respinsa de verificator -- e o eroare
%% de SINTAXA. Gramatica are o singura productie pentru `ask', si ea contine
%% `within'. Nu exista arbore de respins.
%%
%% Acesta e cel mai tare fel de invariant, acelasi ca absenta lui `export_key'
%% din Rust: o regula verificata poate fi dezactivata, uitata sau ocolita; una
%% absenta din gramatica nu poate fi nici macar exprimata.
ask_without_within_is_unrepresentable(_Config) ->
    Source = dawn_variant([{"ask reflection within 1s ->", "ask reflection ->"}]),
    ?assertMatch({error, {syntax, _, _}}, bahmet_compile:string(Source)).

%% Ordinea `tend' ESTE graful de dependenta. Compilatorul nu are voie sa o
%% rearanjeze: sub `rest_for_one', pozitia decide cine se refondeaza cand.
communion_preserves_tend_order(_Config) ->
    {ok, Modules} = bahmet_compile:file(contemplation()),
    {_, Source} = lists:keyfind(council_dawn_council_sup, 1, Modules),
    Ground = position(Source, <<"id => bahmet_ground">>),
    Commons = position(Source, <<"id => bahmet_commons">>),
    Gathering = position(Source, <<"id => council_dawn_gathering_sup">>),
    ?assert(Ground >= 0 andalso Commons > Ground andalso Gathering > Commons),
    ?assertNotEqual(nomatch, binary:match(Source, <<"strategy => rest_for_one">>)),
    ?assertNotEqual(nomatch, binary:match(Source, <<"intensity => 3">>)),
    %% `while_needed' -> `transient': o adunare implinita ramane implinita.
    ?assertNotEqual(nomatch, binary:match(Source, <<"restart => transient">>)).

%% `completes when all present are complete' -> `auto_shutdown'. Intregul isi
%% recunoaste implinirea prin implinirea partilor, fara ca cineva sa numere.
gathering_completes_when_all_do(_Config) ->
    {ok, Modules} = bahmet_compile:file(contemplation()),
    {_, Source} = lists:keyfind(council_dawn_gathering_sup, 1, Modules),
    ?assertNotEqual(nomatch, binary:match(Source, <<"auto_shutdown => all_significant">>)),
    ?assertNotEqual(nomatch, binary:match(Source, <<"significant => true">>)),
    %% `grace' isi gaseste in sfarsit locul: citit din atributele fiintei.
    ?assertNotEqual(nomatch, binary:match(Source, <<"bahmet_grace">>)).

generated_circle_compiles(Config) ->
    Dir = proplists:get_value(priv_dir, Config),
    {ok, Files} = bahmet_compile:to_dir(contemplation(), Dir),
    ?assertEqual(4, length(Files)),
    _ = [?assertMatch({ok, _}, compile:file(F, [return_errors, warnings_as_errors,
                                                {outdir, Dir}, report]))
         || F <- Files],
    ok.

%% BUCLA COMPLETA: text .b27 -> module -> arbore de supervizare viu -> rit
%% executat -> intelepciune adunata. Fara nicio linie de Erlang scrisa de om.
generated_circle_lives(Config) ->
    ok = load_dawn(Config),
    %% Cercul generat isi porneste propriile bahmet_ground si bahmet_commons,
    %% deci nu poate coexista cu aplicatia scrisa de mana. Ii facem loc.
    _ = application:stop(bahmet),
    timer:sleep(150),
    {ok, Sup} = council_dawn_council_sup:start_link(),
    unlink(Sup),
    try
        Questions = [<<"ce inseamna a completa">>, <<"ce inseamna a darui">>],
        Wisdom = council_dawn_rites:convene(Questions),
        ?assertMatch({ok, _}, Wisdom),
        {ok, Tensor} = Wisdom,
        ?assertEqual(bahmet_ground:dimension(), length(Tensor)),
        %% Doua fiinte s-au implinit, deci doua au daruit.
        ?assertEqual(2, length(bahmet_commons:contributors())),
        %% Iar adunarea s-a stins singura cand ultima s-a implinit.
        ?assertEqual(undefined, whereis(council_dawn_gathering_sup))
    after
        stop_sync(Sup),
        timer:sleep(100),
        {ok, _} = application:ensure_all_started(bahmet)
    end.

%%====================================================================
%% Ce refuza -- regulile Fazei 4
%%====================================================================

%% GRAMMAR.md §4.1. Gramatica impune deja `into'; verificatorul cere ca
%% destinatia sa fie chiar o adunare. `Council' e o comuniune, nu o adunare.
rejects_birth_outside_gathering(_Config) ->
    ?assert(refuses(dawn_variant([{"into Gathering with", "into Council with"}]),
                    "proces orfan")).

%% O fiinta pe care nimeni nu o tine si niciun rit nu o naste e cod pentru
%% cineva care nu se poate intampla.
rejects_tending_a_being(_Config) ->
    ?assert(refuses(dawn_variant([{"tend Gathering while_needed",
                                   "tend Contemplator while_needed"}]),
                    "se nasc intr-o adunare")).

rejects_unreachable_being(_Config) ->
    Orphan = "  being Orphan\n"
             "    carries x : count = 0 end\n"
             "    patience 10s\n"
             "    when broken -> release withholding x end\n"
             "  end\n\n"
             "  communion Council",
    ?assert(refuses(dawn_variant([{"  communion Council", Orphan}]),
                    "nu o poate aduce la viata")).

rejects_unknown_harmony(_Config) ->
    ?assert(refuses(dawn_variant([{"harmony     rest_for_one", "harmony     fiecare_pe_cont_propriu"}]),
                    "strategie de supervizare")).

rejects_unknown_completion_rule(_Config) ->
    ?assert(refuses(dawn_variant([{"completes when all present are complete",
                                   "completes when cineva zice asa"}]),
                    "conditia de implinire")).

%% Terminatorii au inteles doar in contextul lor. O clauza `upon' primeste un
%% dar, nu o cerere -- deci nu are cui raspunde.
rejects_answer_in_upon(_Config) ->
    ?assert(refuses(dawn_variant([{"completion merging insight into wisdom",
                                   "answer insight"}]),
                    "primeste un dar")).

rejects_keep_in_rite(_Config) ->
    ?assert(refuses(dawn_variant([{"answer wisdom", "keep"}]),
                    "un rit se termina")).

%%====================================================================
%% Ajutoare
%%====================================================================

%% Radacina proiectului, dedusa din locatia acestei suite. `code:lib_dir'
%% ar arata spre _build, unde dsl/ nu ajunge niciodata.
source() -> dsl("hearth.b27").
contemplation() -> dsl("contemplation.b27").

dsl(File) ->
    Here = filename:dirname(code:which(?MODULE)),
    Parts = filename:split(Here),
    case lists:member("_build", Parts) of
        true ->
            {Before, _} = lists:splitwith(fun(P) -> P =/= "_build" end, Parts),
            filename:join(Before ++ ["dsl", File]);
        false ->
            filename:join(Parts ++ ["..", "dsl", File])
    end.

dawn_variant(Substitutions) ->
    {ok, Binary} = file:read_file(contemplation()),
    lists:foldl(fun({From, To}, Text) ->
                        ?assertNotEqual(nomatch, string:find(Text, From)),
                        lists:flatten(string:replace(Text, From, To))
                end, unicode:characters_to_list(Binary), Substitutions).

position(Source, Needle) ->
    case binary:match(Source, Needle) of
        {Start, _} -> Start;
        nomatch -> -1
    end.

load_dawn(Config) ->
    Dir = proplists:get_value(priv_dir, Config),
    {ok, Files} = bahmet_compile:to_dir(contemplation(), Dir),
    _ = [{ok, _} = compile:file(F, [return_errors, {outdir, Dir}]) || F <- Files],
    true = code:add_patha(Dir),
    _ = [code:load_file(list_to_atom(filename:basename(F, ".erl"))) || F <- Files],
    ok.

stop_sync(Sup) ->
    case is_process_alive(Sup) of
        false -> ok;
        true ->
            Ref = monitor(process, Sup),
            exit(Sup, shutdown),
            receive {'DOWN', Ref, process, Sup, _} -> ok
            after 5000 -> demonitor(Ref, [flush]), exit(Sup, kill), ok
            end
    end.

read() ->
    {ok, Binary} = file:read_file(source()),
    unicode:characters_to_list(Binary).

without(Fragment) -> replace(Fragment, "").

replace(Fragment, Replacement) ->
    variant([{Fragment, Replacement}]).

variant(Substitutions) ->
    lists:foldl(fun({From, To}, Text) ->
                        ?assertNotEqual(nomatch, string:find(Text, From)),
                        lists:flatten(string:replace(Text, From, To))
                end, read(), Substitutions).

%% Un refuz corect spune si DE CE, nu doar unde. Verificam amandoua.
refuses(Source, Expected) ->
    case bahmet_compile:string(Source) of
        {error, Failure = {invariants, _}} ->
            Report = bahmet_compile:report(Failure),
            string:find(Report, Expected) =/= nomatch;
        Other ->
            ct:pal("astept un refuz de invariant, am primit: ~p", [Other]),
            false
    end.

ensure_loaded(Config) ->
    case code:is_loaded(hearth_keeper) of
        false ->
            Dir = proplists:get_value(priv_dir, Config),
            {ok, Files} = bahmet_compile:to_dir(source(), Dir),
            _ = [{ok, _} = compile:file(F, [return_errors, {outdir, Dir}]) || F <- Files],
            true = code:add_patha(Dir),
            _ = [code:load_file(list_to_atom(filename:basename(F, ".erl"))) || F <- Files],
            ok;
        _ ->
            ok
    end.

seed() ->
    Dimension = bahmet_ground:dimension(),
    lists:duplicate(Dimension, 1.0 / Dimension).

wait_gone(Pid) ->
    Ref = monitor(process, Pid),
    receive
        {'DOWN', Ref, process, Pid, _} -> ok
    after 5000 ->
        demonitor(Ref, [flush]),
        {error, timeout}
    end.
