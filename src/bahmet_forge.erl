%%%-------------------------------------------------------------------
%%% @doc bahmet_forge -- AST -> sursa Erlang.
%%%
%%% Produce TEXT, nu forme abstracte. Un compilator care emite cod
%%% inspectabil poate fi verificat citindu-l; unul care emite direct
%%% `erl_syntax' trebuie crezut pe cuvant. Pentru un limbaj a carui intreaga
%%% miza e ca proprietatile sa fie VIZIBILE, alegerea se face singura.
%%%
%%% ═══════════════════════════════════════════════════════════════════
%%%  CE DEDUCE COMPILATORUL SINGUR
%%% ═══════════════════════════════════════════════════════════════════
%%%
%%% Trei lucruri pe care in Faza 1 le-am scris de mana si le-am putut uita:
%%%
%%%   `format_status/1' redacteaza CHIAR campul numit in `completion'.
%%%   Compilatorul stie care camp e cel pretios -- e cel pe care fiinta il
%%%   daruieste -- deci stie si care nu are voie sa apara in jurnale. Nimeni
%%%   nu mai trebuie sa-si aminteasca sa adauge redactarea.
%%%
%%%   `handle_info(timeout, ...)' se genereaza din clauza `upon silence'.
%%%   Tacerea nu e un mesaj primit, e un mesaj care NU a venit; in OTP asta
%%%   inseamna timeout, si traducerea o face compilatorul.
%%%
%%%   `terminate/2' primeste automat clauza de rupere ca ultim caz. Ordinea
%%%   clauzelor -- implinire, retragere, ruptura -- nu poate fi incurcata,
%%%   fiindca nu e scrisa de om.
%%% @end
%%%-------------------------------------------------------------------
-module(bahmet_forge).

-export([circle/1]).

-record(ctx, {
    fields    :: [atom()],
    visible   :: [atom()],
    secret    :: atom() | undefined,   %% campul daruit la `completion'
    commons   :: atom() | undefined,
    counter   :: non_neg_integer()
}).

-spec circle(tuple()) -> [{module(), binary()}].
circle({circle, _Line, CircleName, Decls}) ->
    [being(CircleName, B) || B = {being, _, _, _, _, _} <- Decls].

being(CircleName, {being, _L, BeingName, Fields, Attrs, Clauses}) ->
    Module = module_name(CircleName, BeingName),
    FieldNames = [F || {field, _, F, _, _} <- Fields],
    {Secret, Commons} = completion_target(Clauses),
    Base = #ctx{fields = FieldNames, visible = [], secret = Secret,
                commons = Commons, counter = 0},

    Source = [
        header(Module, CircleName, BeingName, Attrs),
        exports(Clauses),
        record(Fields, Attrs),
        api(Clauses),
        init_fun(Clauses, Base),
        casts(Clauses, Base),
        calls(),
        infos(Clauses, Base),
        terminate_fun(Clauses),
        code_change(),
        format_status(Secret),
        helpers(Secret, Commons, Clauses)
    ],
    {Module, unicode:characters_to_binary(Source)}.

%%====================================================================
%% Antet, exporturi, inregistrare
%%====================================================================

header(Module, CircleName, BeingName, Attrs) ->
    %% `grace' nu are unde ajunge inca -- e `shutdown' din specificatia de
    %% copil, iar `communion' nu e in subsetul Fazei 3. Il pastram ca atribut
    %% de modul in loc sa-l pierdem: o declaratie fara efect erodeaza
    %% increderea in toate celelalte.
    Grace = attr(grace, Attrs, 5000),
    io_lib:format(
      "%%% Generat de Bahmet 27. NU EDITA -- schimba sursa .b27 si recompileaza.~n"
      "%%% Cerc: ~ts   Fiinta: ~ts~n"
      "-module(~s).~n"
      "-behaviour(gen_server).~n"
      "-bahmet_grace(~p).~n~n", [CircleName, BeingName, Module, Grace]).

exports(Clauses) ->
    Api = [io_lib:format("~s/~p", [M, arity(P, G) + 1])
           || {upon, _, M, P, G, _} <- Clauses, M =/= silence],
    ["-export([start_link/2", [[", ", A] || A <- Api], "]).\n",
     "-export([init/1, handle_call/3, handle_cast/2, handle_info/2,\n"
     "         terminate/2, code_change/3, format_status/1]).\n\n"].

arity(Params, undefined) -> length(Params);
arity(Params, _Giver) -> length(Params).

record(Fields, Attrs) ->
    Patience = attr(patience, Attrs, 30000),
    Declared = [io_lib:format("    ~s~s", [F, default(D)]) || {field, _, F, _, D} <- Fields],
    ["-record(state, {\n"
     "    id,\n",
     io_lib:format("    patience = ~p", [Patience]),
     [[",\n", D] || D <- Declared],
     "\n}).\n\n"].

default(undefined) -> "";
default({lit, _, void}) -> " = undefined";
default({lit, _, V}) when is_binary(V) -> io_lib:format(" = ~p", [V]);
default({lit, _, V}) -> io_lib:format(" = ~p", [V]).

attr(Kind, Attrs, Fallback) ->
    case [V || {attr, _, K, V} <- Attrs, K =:= Kind] of
        [V | _] -> V;
        [] -> Fallback
    end.

%%====================================================================
%% API
%%====================================================================

api(Clauses) ->
    ["start_link(Id, Args) ->\n"
     "    gen_server:start_link(?MODULE, {Id, Args}, []).\n\n",
     [api_fun(C) || C = {upon, _, M, _, _, _} <- Clauses, M =/= silence]].

api_fun({upon, _L, Message, Params, Giver, _Body}) ->
    Vars = [var_name(N) || {param, _, N, _} <- Params],
    Args = ["Pid" | Vars],
    Payload = case {Params, Giver} of
                  {[], undefined} -> io_lib:format("~s", [Message]);
                  {_, undefined} -> io_lib:format("{~s~s}", [Message, [[", ", V] || V <- Vars]]);
                  %% `self()' -- daruitorul se numeste pe sine, nu e cerut.
                  {_, _} -> io_lib:format("{~s~s, self()}", [Message, [[", ", V] || V <- Vars]])
              end,
    io_lib:format("~s(~s) ->\n    gen_server:cast(Pid, ~s).\n\n",
                  [Message, string:join(Args, ", "), Payload]).

%%====================================================================
%% init
%%====================================================================

init_fun(Clauses, Ctx) ->
    case [C || C = {awaken, _, _, _} <- Clauses] of
        [{awaken, _L, Params, Body}] ->
            Vars = [var_name(N) || {param, _, N, _} <- Params],
            Visible = [N || {param, _, N, _} <- Params],
            Pattern = io_lib:format("{Id, [~s]}", [string:join(Vars, ", ")]),
            {Lines, Final} = statements(Body, Ctx#ctx{visible = Visible, counter = 0}),
            ["init(", Pattern, ") ->\n",
             %% Fara `trap_exit', ragazul acordat de supervizor la oprire ar
             %% ramane un gest gol: fiinta ar fi ucisa inainte sa daruiasca.
             "    process_flag(trap_exit, true),\n",
             "    S0 = #state{id = Id},\n",
             Lines,
             "    ", init_result(Body, Final), ".\n\n"];
        [] ->
            ["init({Id, _Args}) ->\n"
             "    process_flag(trap_exit, true),\n"
             "    S0 = #state{id = Id},\n"
             "    {ok, S0, S0#state.patience}.\n\n"]
    end.

init_result({body, _, {keep, _}}, S) ->
    io_lib:format("{ok, ~s, ~s#state.patience}", [S, S]);
init_result({body, _, _Other}, S) ->
    %% O nastere care nu se termina in `keep' e o fiinta care moare la
    %% nastere. Legal, dar aproape sigur o greseala; o lasam sa treaca.
    io_lib:format("{ok, ~s, ~s#state.patience}", [S, S]).

%%====================================================================
%% handle_cast / handle_info
%%====================================================================

casts(Clauses, Ctx) ->
    Handlers = [cast(C, Ctx) || C = {upon, _, M, _, _, _} <- Clauses, M =/= silence],
    [Handlers,
     %% Un mesaj de neinteles nu e motiv de moarte. Trece, si rabdarea se
     %% reinnoieste.
     "handle_cast(_Ignored, S) ->\n"
     "    {noreply, S, S#state.patience}.\n\n"].

cast({upon, _L, Message, Params, Giver, Body}, Ctx) ->
    Vars = [var_name(N) || {param, _, N, _} <- Params],
    Visible = [N || {param, _, N, _} <- Params] ++ [G || G <- [Giver], G =/= undefined],
    Pattern = case {Params, Giver} of
                  {[], undefined} -> io_lib:format("~s", [Message]);
                  {_, undefined} -> io_lib:format("{~s~s}", [Message, [[", ", V] || V <- Vars]]);
                  {_, _} -> io_lib:format("{~s~s, ~s}",
                                          [Message, [[", ", V] || V <- Vars], var_name(Giver)])
              end,
    {Lines, Final} = statements(Body, Ctx#ctx{visible = Visible, counter = 0}),
    ["handle_cast(", Pattern, ", S0) ->\n", Lines,
     "    ", terminator(Body, Final), ";\n"].

calls() ->
    ["handle_call(_Request, _From, S) ->\n"
     "    {reply, {error, unknown_request}, S, S#state.patience}.\n\n"].

infos(Clauses, Ctx) ->
    Silence = case [C || C = {upon, _, silence, _, _, _} <- Clauses] of
                  [{upon, _L, silence, _P, _G, Body}] ->
                      {Lines, Final} = statements(Body, Ctx#ctx{visible = [], counter = 0}),
                      %% Tacerea nu e un mesaj primit, e unul care nu a venit.
                      %% In OTP asta se numeste timeout.
                      ["handle_info(timeout, S0) ->\n", Lines,
                       "    ", terminator(Body, Final), ";\n"];
                  [] ->
                      "handle_info(timeout, S) ->\n"
                      "    {stop, {shutdown, silence}, S};\n"
              end,
    [Silence,
     "handle_info({'EXIT', _Pid, Reason}, S) ->\n"
     "    {stop, Reason, S};\n"
     "handle_info(_Info, S) ->\n"
     "    {noreply, S, S#state.patience}.\n\n"].

%%====================================================================
%% terminate -- ordinea nu poate fi incurcata, fiindca nu o scrie un om
%%====================================================================

terminate_fun(Clauses) ->
    Body = case gives_on_exit(Clauses) of
               true -> "offer_up(S)";
               false -> "ok"
           end,
    %% Clauza de ruptura se GENEREAZA din ce a scris autorul, nu se codifica
    %% rigid. Verificatorul cere ca decizia sa fie luata; ar fi fost mai rau
    %% decat sa nu intrebam daca apoi am fi ignorat raspunsul.
    {BrokenVar, BrokenBody, BrokenWhy} =
        case broken_gives(Clauses) of
            true ->
                {"S", "offer_up(S)",
                 "%% Ruptura: autorul a cerut explicit sa se daruiasca si asa.\n"};
            false ->
                {"_S", "ok",
                 "%% Ruptura: NU daruieste. O stare pe jumatate scrisa ar otravi\n"
                 "%% tacut fiecare intuitie viitoare a fiecarei fiinte.\n"}
        end,
    ["%% Implinire: drumul dus pana la capat.\n"
     "terminate(normal, S) -> ", Body, ";\n"
     "%% Retragere altruista: daruieste si cand plecarea nu a fost alegerea ei.\n"
     "terminate(shutdown, S) -> ", Body, ";\n"
     "terminate({shutdown, _Why}, S) -> ", Body, ";\n",
     BrokenWhy,
     "terminate(_Broken, ", BrokenVar, ") -> ", BrokenBody, ".\n\n"].

code_change() ->
    "code_change(_OldVsn, S, _Extra) -> {ok, S}.\n\n".

%% Compilatorul stie care camp e pretios -- e cel daruit la `completion' --
%% deci stie si care nu are voie sa apara in jurnale.
format_status(undefined) ->
    "format_status(Status) -> Status.\n\n";
format_status(Secret) ->
    io_lib:format(
      "format_status(Status = #{state := S}) ->\n"
      "    Status#{state => S#state{~s = redacted}};\n"
      "format_status(Status) -> Status.\n\n", [Secret]).

helpers(Secret, Commons, Clauses) ->
    Give = case gives_on_exit(Clauses) orelse broken_gives(Clauses) of
               false -> "";
               true ->
                   io_lib:format(
                     "%% `cast', nu `call': fiinta care pleaca nu are voie sa fie\n"
                     "%% tinuta in loc de starea bunului comun.\n"
                     "offer_up(#state{~s = undefined}) -> ok;\n"
                     "offer_up(#state{~s = redacted}) -> ok;\n"
                     "offer_up(S) -> ~s:merge(S#state.id, S#state.~s).\n\n",
                     [Secret, Secret, commons_module(Commons), Secret])
           end,
    Intuit = case uses_intuit(Clauses) of
                 false -> "";
                 true ->
                     "intuit_(Offering) ->\n"
                     "    {ok, Result} = bahmet_deep:intuit(bahmet_ground:ground(), Offering),\n"
                     "    Result.\n"
             end,
    [Give, Intuit].

commons_module(_Name) -> "bahmet_commons".

%%====================================================================
%% Corpuri: fiecare legare avanseaza starea
%%====================================================================

%% Fiecare legare produce o stare noua: S0, S1, S2... Nu mutam nimic, ceea ce
%% face ca ordinea sa fie citibila si ca o expresie sa nu poata vedea vreodata
%% o stare pe jumatate actualizata.
statements({body, Stmts, _Terminator}, Ctx) ->
    {Acc, N} = lists:foldl(
        fun(Stmt, {Lines, K}) ->
            {Line, Next} = statement(Stmt, Ctx, state_var(K)),
            {[Lines, Line], Next}
        end, {[], 0}, Stmts),
    {Acc, state_var(N)}.

statement({bind, _L, Target, Expr}, Ctx, Current) ->
    Next = next_index(Current),
    Code = expression(Expr, Ctx, Current),
    {io_lib:format("    ~s = ~s#state{~s = ~s},~n",
                   [state_var(Next), Current, Target, Code]), Next};
statement({offer, _L, {call, _, Message, Args}, Target}, Ctx, Current) ->
    Payload = case Args of
                  [] -> io_lib:format("~s", [Message]);
                  _ -> io_lib:format("{~s~s}", [Message,
                        [[", ", expression(A, Ctx, Current)] || A <- Args]])
              end,
    {io_lib:format("    gen_server:cast(~s, ~s),~n",
                   [expression(Target, Ctx, Current), Payload]),
     index_of(Current)}.

terminator({body, _, {keep, _}}, S) ->
    io_lib:format("{noreply, ~s, ~s#state.patience}", [S, S]);
terminator({body, _, {completion, _, _, _}}, S) ->
    %% `normal'. Cuvantul conteaza: supervizorul e `transient', deci `normal'
    %% inseamna „a reusit, lasati-o in pace".
    io_lib:format("{stop, normal, ~s}", [S]);
terminator({body, _, {release, _, quietly, _}}, S) ->
    io_lib:format("{stop, {shutdown, silence}, ~s}", [S]);
terminator({body, _, {release, _, withholding, _}}, S) ->
    io_lib:format("{stop, {shutdown, withheld}, ~s}", [S]).

%%====================================================================
%% Expresii
%%====================================================================

expression({intuit, _L, _Ground, Inner}, Ctx, S) ->
    io_lib:format("intuit_(~s)", [expression(Inner, Ctx, S)]);
expression({add, _L, Left, Right}, Ctx, S) ->
    io_lib:format("(~s + ~s)", [expression(Left, Ctx, S), expression(Right, Ctx, S)]);
expression({call, _L, Name, Args}, Ctx, S) ->
    io_lib:format("{~s~s}", [Name, [[", ", expression(A, Ctx, S)] || A <- Args]]);
expression({var, _L, Name}, Ctx, S) ->
    case lists:member(Name, Ctx#ctx.fields) of
        true -> io_lib:format("~s#state.~s", [S, Name]);
        false -> var_name(Name)
    end;
expression({lit, _L, void}, _Ctx, _S) -> "undefined";
expression({lit, _L, Value}, _Ctx, _S) -> io_lib:format("~p", [Value]).

%%====================================================================
%% Ajutoare
%%====================================================================

state_var(N) -> "S" ++ integer_to_list(N).

next_index(Current) -> index_of(Current) + 1.

index_of(Current) -> list_to_integer(tl(lists:flatten(Current))).

var_name(Atom) ->
    [First | Rest] = atom_to_list(Atom),
    [string:to_upper(First) | Rest].

module_name(CircleName, BeingName) ->
    list_to_atom(lists:flatten([slug(CircleName), "_", slug(BeingName)])).

slug(Bin) ->
    Lower = string:lowercase(unicode:characters_to_list(Bin)),
    [case C of $. -> $_; _ -> C end || C <- Lower].

%% Campul daruit -- pe orice cale de iesire, nu doar la `completion'. E si
%% campul redactat in jurnale: ce merita daruit deliberat e exact ce nu are
%% voie sa se scurga din intamplare.
completion_target(Clauses) ->
    Given =
        [{F, C} || {upon, _, _, _, _, {body, _, {completion, _, {var, _, F}, C}}} <- Clauses]
        ++ [{F, undefined} || {upon, _, _, _, _, {body, _, {release, _, quietly, {var, _, F}}}} <- Clauses]
        ++ [{F, undefined} || {broken, _, {body, _, {release, _, quietly, {var, _, F}}}} <- Clauses],
    case Given of
        [{Field, Target} | _] -> {Field, Target};
        [] -> {undefined, undefined}
    end.

%% Daruieste pe caile normale de iesire (implinire sau retragere linistita)?
gives_on_exit(Clauses) ->
    lists:any(fun({upon, _, _, _, _, {body, _, {completion, _, _, _}}}) -> true;
                 ({upon, _, _, _, _, {body, _, {release, _, quietly, E}}}) -> E =/= undefined;
                 (_) -> false
              end, Clauses).

%% Daruieste si cand s-a rupt? Raspunsul il da autorul, nu compilatorul.
broken_gives(Clauses) ->
    lists:any(fun({broken, _, {body, _, {release, _, quietly, E}}}) -> E =/= undefined;
                 ({broken, _, {body, _, {completion, _, _, _}}}) -> true;
                 (_) -> false
              end, Clauses).

uses_intuit(Clauses) ->
    lists:any(fun(C) -> has_intuit(C) end, Clauses).

has_intuit({upon, _, _, _, _, Body}) -> body_has_intuit(Body);
has_intuit({awaken, _, _, Body}) -> body_has_intuit(Body);
has_intuit({broken, _, Body}) -> body_has_intuit(Body);
has_intuit(_) -> false.

body_has_intuit({body, Stmts, _}) ->
    lists:any(fun({bind, _, _, E}) -> expr_has_intuit(E);
                 (_) -> false
              end, Stmts).

expr_has_intuit({intuit, _, _, _}) -> true;
expr_has_intuit({add, _, L, R}) -> expr_has_intuit(L) orelse expr_has_intuit(R);
expr_has_intuit({call, _, _, Args}) -> lists:any(fun expr_has_intuit/1, Args);
expr_has_intuit(_) -> false.
