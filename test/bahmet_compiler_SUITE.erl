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
                          reports_syntax_error_with_line]},
     {refuses, [parallel], [rejects_missing_broken_clause,
                            rejects_missing_patience,
                            rejects_unknown_commons,
                            rejects_unknown_ground,
                            rejects_bind_outside_carries,
                            rejects_unknown_variable,
                            rejects_duplicate_message,
                            rejects_incomplete_ground]},
     {generates, [], [generated_module_compiles,
                      generated_being_completes_and_gives,
                      generated_being_withholds_when_broken,
                      generated_status_is_redacted,
                      broken_clause_body_is_honoured,
                      grace_survives_into_attributes]}].

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
    ?assertMatch([{hearth_keeper, _}], Modules).

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
    {ok, [File]} = bahmet_compile:to_dir(source(), Dir),
    %% `warnings_as_errors': cod generat cu avertismente e cod generat prost.
    ?assertMatch({ok, hearth_keeper},
                 compile:file(File, [return_errors, warnings_as_errors,
                                     {outdir, Dir}, report])),
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
    {ok, [{Module, Code}]} = bahmet_compile:string(Source),
    ?assertEqual(hearth_giving_keeper, Module),

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
%% Ajutoare
%%====================================================================

%% Radacina proiectului, dedusa din locatia acestei suite. `code:lib_dir'
%% ar arata spre _build, unde dsl/ nu ajunge niciodata.
source() ->
    Here = filename:dirname(code:which(?MODULE)),
    root(filename:split(Here)).

root(Parts) ->
    case lists:member("_build", Parts) of
        true ->
            {Before, _} = lists:splitwith(fun(P) -> P =/= "_build" end, Parts),
            filename:join(Before ++ ["dsl", "hearth.b27"]);
        false ->
            filename:join(Parts ++ ["..", "dsl", "hearth.b27"])
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
            {ok, [File]} = bahmet_compile:to_dir(source(), Dir),
            {ok, hearth_keeper} = compile:file(File, [return_errors, {outdir, Dir}]),
            true = code:add_patha(Dir),
            {module, hearth_keeper} = code:load_file(hearth_keeper),
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
