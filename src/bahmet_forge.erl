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
    lists:flatten([
        [being(CircleName, B) || B = {being, _, _, _, _, _} <- Decls],
        [gathering(CircleName, G) || G = {gathering, _, _, _, _, _} <- Decls],
        [communion(CircleName, C, Decls) || C = {communion, _, _, _, _, _} <- Decls],
        rites(CircleName, Decls)
    ]).

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
        calls(Clauses, Base),
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

calls(Clauses, Ctx) ->
    [[ask(C, Ctx) || C = {ask, _, _, _, _} <- Clauses],
     "handle_call(_Request, _From, S) ->\n"
     "    {reply, {error, unknown_request}, S, S#state.patience}.\n\n"].

%% `ask' e singura forma sincrona, si gramatica a impus deja `within'. Aici
%% doar traducem: limita declarata in sursa devine limita reala a apelantului.
ask({ask, _L, Message, _Within, Body}, Ctx) ->
    {Lines, Final} = statements(Body, Ctx#ctx{visible = [], counter = 0}),
    {body, _Stmts, Terminator} = Body,
    Answer = case Terminator of
                 {answer, _, Expr} ->
                     io_lib:format("    Answer = ~s,~n",
                                   [expression(Expr, Ctx, Final)]);
                 _ ->
                     "    Answer = ok,\n"
             end,
    ["handle_call(", atom_to_list(Message), ", _From, S0) ->\n", Lines, Answer,
     io_lib:format("    {reply, Answer, ~s, ~s#state.patience};~n", [Final, Final])].

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
    io_lib:format("{stop, {shutdown, withheld}, ~s}", [S]);
terminator({body, _, {answer, _, _}}, S) ->
    io_lib:format("{noreply, ~s, ~s#state.patience}", [S, S]).

%%====================================================================
%% Expresii
%%====================================================================

expression({intuit, _L, _Ground, Inner}, Ctx, S) ->
    io_lib:format("intuit_(~s)", [expression(Inner, Ctx, S)]);
expression({reflect, _L, _Ground}, _Ctx, _S) ->
    "bahmet_deep:reflect(bahmet_ground:ground())";
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

slug(Bin) when is_atom(Bin) -> slug(atom_to_binary(Bin, utf8));
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

%%====================================================================
%% ADUNAREA -- supervizor dinamic
%%
%% Aici scheletul scris de mana in Faza 1 (bahmet_council_sup) devine iesire
%% de compilator. Cele trei chei OTP care fac „implinirea" sa fie structurala
%% -- `transient', `significant', `auto_shutdown' -- nu mai sunt scrise de un
%% om care si le aminteste, ci deduse din `harmony', `forbearance' si
%% `completes when'.
%%====================================================================

gathering(CircleName, {gathering, _L, Name, Harmony, Forbearance, Rule}) ->
    Module = sup_name(CircleName, Name),
    {harmony, _, Strategy} = Harmony,
    {forbearance, _, Intensity, Period} = Forbearance,
    AutoShutdown = case Rule of
                       undefined -> "never";
                       {completes, _, _} -> "all_significant"
                   end,
    Source =
        [io_lib:format(
           "%%% Generat de Bahmet 27. NU EDITA.~n"
           "%%% Adunarea `~ts' din cercul `~ts'.~n"
           "-module(~s).~n"
           "-behaviour(supervisor).~n~n"
           "-export([start_link/0, birth/2, present/0, await_completion/1, init/1]).~n~n"
           "start_link() ->~n"
           "    supervisor:start_link({local, ?MODULE}, ?MODULE, []).~n~n"
           "init([]) ->~n"
           "    SupFlags = #{strategy => ~s,~n"
           "                 intensity => ~p,~n"
           "                 period => ~p,~n"
           %% `all_significant': intregul isi recunoaste propria implinire PRIN
           %% implinirea partilor. Nimeni nu numara, nimeni nu sondeaza.
           "                 auto_shutdown => ~s},~n"
           "    %% Pornim goi. Un cerc nu se naste plin -- el se aduna.~n"
           "    {ok, {SupFlags, []}}.~n~n",
           [Name, CircleName, Module, Strategy, Intensity, Period div 1000, AutoShutdown]),
         birth_fun(),
         present_fun(),
         await_fun()],
    {Module, unicode:characters_to_binary(Source)}.

birth_fun() ->
    %% `grace' isi gaseste in sfarsit locul. Fiinta si-l poarta ca atribut de
    %% modul, iar adunarea il citeste: ragazul declarat in sursa devine
    %% `shutdown' in specificatia de copil.
    "birth(Module, Args) ->\n"
    "    %% Identitatea e un intreg unic, NU un atom: tabela de atomi nu se\n"
    "    %% colecteaza niciodata, iar un sistem care naste liber si-ar sapa\n"
    "    %% groapa lent, murind brusc luni mai tarziu.\n"
    "    Id = {born, erlang:unique_integer([positive, monotonic])},\n"
    "    Grace = case lists:keyfind(bahmet_grace, 1, Module:module_info(attributes)) of\n"
    "                {bahmet_grace, [G]} -> G;\n"
    "                _ -> 5000\n"
    "            end,\n"
    "    Spec = #{id => Id,\n"
    "             start => {Module, start_link, [Id, Args]},\n"
    "             %% `transient': implinirea nu e esec. Terminarea normala nu\n"
    "             %% se reporneste -- supervizorul respecta lucrul terminat.\n"
    "             restart => transient,\n"
    "             significant => true,\n"
    "             shutdown => Grace,\n"
    "             type => worker,\n"
    "             modules => [Module]},\n"
    "    supervisor:start_child(?MODULE, Spec).\n\n".

present_fun() ->
    "%% Cine e viu ACUM. Un copil `transient' implinit ramane in lista cu\n"
    "%% pid-ul `undefined': supervizorul isi aminteste ca a existat, dar nu\n"
    "%% il reinvie. Raspundem la „cine e prezent\", nu la „cine a fost\".\n"
    "present() ->\n"
    "    [Pid || {_Id, Pid, _Type, _Mods} <- supervisor:which_children(?MODULE),\n"
    "            is_pid(Pid)].\n\n".

await_fun() ->
    "%% Asteptam prin monitorizare, nu prin sondare. A intreba repetat „ai\n"
    "%% terminat?\" e nerabdare deghizata in cod; un monitor costa zero pana\n"
    "%% in clipa in care chiar se intampla ceva.\n"
    "await_completion(Timeout) ->\n"
    "    case whereis(?MODULE) of\n"
    "        undefined -> complete;\n"
    "        Pid ->\n"
    "            Ref = erlang:monitor(process, Pid),\n"
    "            receive\n"
    "                {'DOWN', Ref, process, Pid, _Reason} -> complete\n"
    "            after Timeout ->\n"
    "                erlang:demonitor(Ref, [flush]),\n"
    "                {timeout, Pid}\n"
    "            end\n"
    "    end.\n".

%%====================================================================
%% COMUNIUNEA -- perspectiva globala
%%
%% Ordinea copiilor NU e stilistica: e graful de dependenta, exact asa cum a
%% scris-o autorul in `tend'. `rest_for_one' o transforma in politica de
%% repornire, iar compilatorul nu are voie sa o rearanjeze.
%%====================================================================

communion(CircleName, {communion, _L, Name, Harmony, Forbearance, Tends}, Decls) ->
    Module = sup_name(CircleName, Name),
    {harmony, _, Strategy} = Harmony,
    {forbearance, _, Intensity, Period} = Forbearance,
    Children = [child(CircleName, T, Decls) || T <- Tends],
    Source =
        [io_lib:format(
           "%%% Generat de Bahmet 27. NU EDITA.~n"
           "%%% Comuniunea `~ts' din cercul `~ts'.~n"
           "-module(~s).~n"
           "-behaviour(supervisor).~n~n"
           "-export([start_link/0, init/1]).~n~n"
           "start_link() ->~n"
           "    supervisor:start_link({local, ?MODULE}, ?MODULE, []).~n~n"
           "init([]) ->~n"
           "    SupFlags = #{strategy => ~s,~n"
           %% Ingaduinta marginita: cand pragul e depasit, supervizorul renunta
           %% la propria autoritate si preda situatia unei vederi mai largi.
           "                 intensity => ~p,~n"
           "                 period => ~p,~n"
           "                 auto_shutdown => never},~n"
           "    Children = [~n",
           [Name, CircleName, Module, Strategy, Intensity, Period div 1000]),
         string:join(Children, ",\n"),
         "\n    ],\n"
         "    {ok, {SupFlags, Children}}.\n"],
    {Module, unicode:characters_to_binary(Source)}.

child(CircleName, {tend, _L, Target, Lifetime}, Decls) ->
    {Id, Start, Type, Shutdown} = tend_target(CircleName, Target, Decls),
    lists:flatten(io_lib:format(
      "        #{id => ~s,~n"
      "          start => {~s, start_link, []},~n"
      "          restart => ~s,~n"
      "          shutdown => ~s,~n"
      "          type => ~s,~n"
      "          modules => [~s]}",
      [Id, Start, restart_of(Lifetime), Shutdown, Type, Start])).

%% Temeliile si bunurile comune se leaga la modulele de rulare scrise de mana;
%% adunarile, la supervizorul generat pentru ele.
tend_target(_CircleName, {small, Name}, Decls) ->
    case [C || {commons, _, C, _} <- Decls, C =:= Name] of
        [_ | _] -> {"bahmet_commons", "bahmet_commons", "worker", "5000"};
        [] -> {"bahmet_ground", "bahmet_ground", "worker", "5000"}
    end;
tend_target(CircleName, {great, Name}, _Decls) ->
    Module = atom_to_list(sup_name(CircleName, Name)),
    %% `shutdown => infinity' e obligatoriu pentru copiii de tip supervizor:
    %% nu avem dreptul sa punem un cronometru peste plecarea altora.
    {Module, Module, "supervisor", "infinity"}.

restart_of(always) -> "permanent";
restart_of(while_needed) -> "transient";
restart_of(once) -> "temporary".

%%====================================================================
%% RITURILE
%%====================================================================

rites(CircleName, Decls) ->
    case [R || R = {rite, _, _, _, _} <- Decls] of
        [] -> [];
        Rites -> [rites_module(CircleName, Rites, Decls)]
    end.

rites_module(CircleName, Rites, Decls) ->
    Module = list_to_atom(lists:flatten([slug(CircleName), "_rites"])),
    Exports = [io_lib:format("~s/~p", [N, length(P)]) || {rite, _, N, P, _} <- Rites],
    Functions = [rite_fun(CircleName, R, Decls) || R <- Rites],
    %% Emitem doar ajutoarele chemate. O functie nefolosita ar fi un
    %% avertisment, iar cod generat cu avertismente e cod generat prost.
    Body = unicode:characters_to_binary(Functions),
    Helpers =
        [["tensor_origin(N) -> lists:duplicate(N, 1.0 / N).\n\n"]
         || binary:match(Body, <<"tensor_origin(">>) =/= nomatch]
        ++ [["intuit_(Offering) ->\n"
             "    {ok, Result} = bahmet_deep:intuit(bahmet_ground:ground(), Offering),\n"
             "    Result.\n"]
            || binary:match(Body, <<"intuit_(">>) =/= nomatch],
    Source =
        [io_lib:format(
           "%%% Generat de Bahmet 27. NU EDITA.~n"
           "%%% Riturile cercului `~ts'.~n"
           "-module(~s).~n~n"
           "-export([~s]).~n~n",
           [CircleName, Module, string:join(Exports, ", ")]),
         Body, Helpers],
    {Module, unicode:characters_to_binary(Source)}.

rite_fun(CircleName, {rite, _L, Name, Params, Body}, Decls) ->
    Vars = [var_name(N) || {param, _, N, _} <- Params],
    Env = #{circle => CircleName, decls => Decls},
    {body, Stmts, Terminator} = Body,
    [io_lib:format("~s(~s) ->~n", [Name, string:join(Vars, ", ")]),
     [rite_stmt(S, Env, "    ") || S <- Stmts],
     "    ", rite_answer(Terminator, Env), ".\n\n"].

rite_stmt({'let', _L, Name, {birth, _, Being, Gathering, Args}}, Env, Indent) ->
    #{circle := Circle} = Env,
    io_lib:format("~s{ok, ~s} = ~s:birth(~s, [~s]),~n",
                  [Indent, var_name(Name),
                   sup_name(Circle, Gathering),
                   module_name(Circle, Being),
                   string:join([rite_expr(A, Env) || A <- Args], ", ")]);
rite_stmt({'let', _L, Name, Expr}, Env, Indent) ->
    io_lib:format("~s~s = ~s,~n", [Indent, var_name(Name), rite_expr(Expr, Env)]);
rite_stmt({offer, _L, {call, _, Message, Args}, Target}, Env, Indent) ->
    io_lib:format("~sgen_server:cast(~s, ~s),~n",
                  [Indent, rite_expr(Target, Env), payload(Message, Args, Env)]);
rite_stmt({foreach, _L, Name, Over, Inner}, Env, Indent) ->
    [io_lib:format("~slists:foreach(fun(~s) ->~n", [Indent, var_name(Name)]),
     [rite_stmt(S, Env, Indent ++ "    ") || S <- Inner],
     io_lib:format("~s    ok~n~send, ~s),~n", [Indent, Indent, rite_expr(Over, Env)])];
rite_stmt({await, _L, Gathering, Within}, Env, Indent) ->
    #{circle := Circle} = Env,
    %% Un `await' care expira nu e „poate a mers": e un rit care nu s-a
    %% implinit. Spunem asta zgomotos, cu numele adunarii in eroare.
    io_lib:format("~scase ~s:await_completion(~p) of~n"
                  "~s    complete -> ok;~n"
                  "~s    Otherwise -> erlang:error({await_failed, ~p, Otherwise})~n"
                  "~send,~n",
                  [Indent, sup_name(Circle, Gathering), Within,
                   Indent, Indent, Gathering, Indent]).

%% Forma unui mesaj e determinata de NUMELE lui in cerc, nu de locul din care
%% e trimis. Daca fiinta care il primeste a scris `from giver', expeditorul
%% TREBUIE sa se numeasca -- altfel tuplul nu se potriveste, iar darul cade
%% tacut in clauza de mesaje neintelese. Fara nicio eroare, fara niciun semn.
payload(Message, Args, Env) ->
    #{decls := Decls} = Env,
    Rendered = [lists:flatten(rite_expr(A, Env)) || A <- Args],
    Parts = Rendered ++ ["self()" || wants_giver(Message, Decls)],
    case Parts of
        [] -> atom_to_list(Message);
        _ -> lists:flatten(io_lib:format("{~s, ~s}", [Message, string:join(Parts, ", ")]))
    end.

wants_giver(Message, Decls) ->
    lists:any(
      fun({being, _, _, _, _, Clauses}) ->
              lists:any(fun({upon, _, M, _, Giver, _}) ->
                                M =:= Message andalso Giver =/= undefined;
                           (_) -> false
                        end, Clauses);
         (_) -> false
      end, Decls).

rite_answer({answer, _L, Expr}, Env) -> rite_expr(Expr, Env);
rite_answer(_Other, _Env) -> "ok".

rite_expr({birth, _L, Being, Gathering, Args}, Env) ->
    #{circle := Circle} = Env,
    io_lib:format("~s:birth(~s, [~s])",
                  [sup_name(Circle, Gathering), module_name(Circle, Being),
                   string:join([rite_expr(A, Env) || A <- Args], ", ")]);
rite_expr({reach, _L, Gathering, present}, Env) ->
    #{circle := Circle} = Env,
    io_lib:format("~s:present()", [sup_name(Circle, Gathering)]);
rite_expr({builtin, _L, tensor, origin, [Arg]}, Env) ->
    io_lib:format("tensor_origin(~s)", [rite_expr(Arg, Env)]);
rite_expr({intuit, _L, _Ground, Inner}, Env) ->
    io_lib:format("intuit_(~s)", [rite_expr(Inner, Env)]);
rite_expr({reflect, _L, _Ground}, _Env) ->
    "bahmet_deep:reflect(bahmet_ground:ground())";
rite_expr({add, _L, Left, Right}, Env) ->
    io_lib:format("(~s + ~s)", [rite_expr(Left, Env), rite_expr(Right, Env)]);
rite_expr({call, _L, Name, Args}, Env) ->
    io_lib:format("{~s~s}", [Name, [[", ", rite_expr(A, Env)] || A <- Args]]);
rite_expr({var, _L, Name}, Env) ->
    #{decls := Decls} = Env,
    %% Un `commons' numit intr-o expresie inseamna „ce s-a adunat acolo".
    case [C || {commons, _, C, _} <- Decls, C =:= Name] of
        [_ | _] -> io_lib:format("bahmet_commons:~s()", [Name]);
        [] -> var_name(Name)
    end;
rite_expr({lit, _L, void}, _Env) -> "undefined";
rite_expr({lit, _L, Value}, _Env) -> io_lib:format("~p", [Value]).

sup_name(CircleName, Name) ->
    list_to_atom(lists:flatten([slug(CircleName), "_", slug(Name), "_sup"])).
