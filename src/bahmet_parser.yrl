%%%-------------------------------------------------------------------
%%% Bahmet 27 -- analizorul sintactic (yecc). Gramatica intreaga.
%%%
%%% NOTA DE PROIECTARE: numele neterminalelor nu au voie sa coincida cu
%%% cuvintele-cheie -- in Erlang `circle' si `'circle'' sunt acelasi atom.
%%% De aici sufixele `_decl' si `_clause', si radacina numita `unit'.
%%%
%%% ═══════════════════════════════════════════════════════════════════
%%%  INVARIANTUL CARE NU E VERIFICAT, CI NEREPREZENTABIL
%%% ═══════════════════════════════════════════════════════════════════
%%%
%%% GRAMMAR.md §4.2 cere ca nicio cerere sincrona sa nu fie nemarginita.
%%% Uita-te la `ask_clause': exista o singura productie, si ea contine
%%% `within' obligatoriu. Nu exista arbore sintactic pentru o cerere fara
%%% limita, deci verificatorul nu are ce respinge.
%%%
%%% Acesta e cel mai puternic fel de invariant. O regula verificata poate fi
%%% dezactivata, uitata sau ocolita; una absenta din gramatica nu poate fi
%%% nici macar exprimata. Acelasi principiu ca la `export_key' in Rust.
%%%
%%% La fel `await ... within' si `forbearance ... within': orice asteptare
%%% din acest limbaj isi poarta termenul in sintaxa.
%%%-------------------------------------------------------------------

Nonterminals
unit decls decl
ground_decl settings setting commons_decl
being_decl carries_block fields field attrs attr
clauses clause awaken_clause upon_clause ask_clause broken_clause
communion_decl gathering_decl harmony_spec forbearance_spec
tends tend_spec tend_target completion_rule words
rite_decl
body stmts stmt message terminator
expr term call qualified args params param type literal.

Terminals
'circle' 'being' 'carries' 'end'
'patience' 'grace'
'awaken' 'with' 'upon' 'from'
'keep' 'completion' 'merging' 'into'
'release' 'quietly' 'giving' 'withholding'
'when' 'broken'
'offer' 'to' 'intuit' 'reflect'
'commons' 'ground'
'communion' 'gathering' 'harmony' 'forbearance' 'tend' 'completes'
'rite' 'let' 'for' 'each' 'in' 'birth' 'await' 'answer'
'ask' 'within'
'text' 'count' 'tensor' 'list' 'of' 'void'
'<-' '->' ':' ',' '(' ')' '[' ']' '=' '+' '.'
ident name int float string duration.

Rootsymbol unit.

unit -> 'circle' name decls 'end' : {circle, line('$1'), value('$2'), '$3'}.

decls -> decl decls : ['$1' | '$2'].
decls -> decl : ['$1'].

decl -> ground_decl : '$1'.
decl -> commons_decl : '$1'.
decl -> being_decl : '$1'.
decl -> communion_decl : '$1'.
decl -> gathering_decl : '$1'.
decl -> rite_decl : '$1'.

%%--------------------------------------------------------------------
%% Temelia si bunul comun
%%--------------------------------------------------------------------

ground_decl -> 'ground' ident settings 'end' :
    {ground, line('$1'), value('$2'), '$3'}.

settings -> setting settings : ['$1' | '$2'].
settings -> setting : ['$1'].
setting -> ident int : {value('$1'), value('$2'), line('$1')}.

commons_decl -> 'commons' ident ':' type :
    {commons, line('$1'), value('$2'), '$4'}.

%%--------------------------------------------------------------------
%% Fiinta
%%--------------------------------------------------------------------

being_decl -> 'being' name carries_block attrs clauses 'end' :
    {being, line('$1'), value('$2'), '$3', '$4', '$5'}.

carries_block -> 'carries' fields 'end' : '$2'.

fields -> field fields : ['$1' | '$2'].
fields -> field : ['$1'].

field -> ident ':' type : {field, line('$1'), value('$1'), '$3', undefined}.
field -> ident ':' type '=' literal : {field, line('$1'), value('$1'), '$3', '$5'}.

%% Atributele si clauzele pot lipsi din gramatica, DELIBERAT. O fiinta fara
%% `patience' sau fara `when broken' trebuie sa produca o eroare care spune
%% ce lipseste si de ce, nu un „syntax error" care spune doar unde.
attrs -> '$empty' : [].
attrs -> attr attrs : ['$1' | '$2'].

attr -> 'patience' duration : {attr, line('$1'), patience, value('$2')}.
attr -> 'grace' duration : {attr, line('$1'), grace, value('$2')}.

clauses -> '$empty' : [].
clauses -> clause clauses : ['$1' | '$2'].

clause -> awaken_clause : '$1'.
clause -> upon_clause : '$1'.
clause -> ask_clause : '$1'.
clause -> broken_clause : '$1'.

awaken_clause -> 'awaken' 'with' '(' params ')' '->' body 'end' :
    {awaken, line('$1'), '$4', '$7'}.

upon_clause -> 'upon' ident '(' params ')' 'from' ident '->' body 'end' :
    {upon, line('$1'), value('$2'), '$4', value('$7'), '$9'}.
upon_clause -> 'upon' ident '(' params ')' '->' body 'end' :
    {upon, line('$1'), value('$2'), '$4', undefined, '$7'}.
upon_clause -> 'upon' ident '->' body 'end' :
    {upon, line('$1'), value('$2'), [], undefined, '$4'}.

%% O SINGURA productie, si `within' e in ea. Vezi antetul.
ask_clause -> 'ask' ident 'within' duration '->' body 'end' :
    {ask, line('$1'), value('$2'), value('$4'), '$6'}.

broken_clause -> 'when' 'broken' '->' body 'end' :
    {broken, line('$1'), '$4'}.

%%--------------------------------------------------------------------
%% Comuniunea si adunarea
%%--------------------------------------------------------------------

communion_decl -> 'communion' name harmony_spec forbearance_spec tends 'end' :
    {communion, line('$1'), value('$2'), '$3', '$4', '$5'}.

gathering_decl -> 'gathering' name harmony_spec forbearance_spec completion_rule 'end' :
    {gathering, line('$1'), value('$2'), '$3', '$4', '$5'}.

%% Strategia e un `ident', nu un cuvant-cheie. Trei nume rezervate in plus
%% ar fi costat mai mult decat verificarea pe care o face bahmet_check.
harmony_spec -> 'harmony' ident : {harmony, line('$1'), value('$2')}.

forbearance_spec -> 'forbearance' int 'within' duration :
    {forbearance, line('$1'), value('$2'), value('$4')}.

tends -> tend_spec tends : ['$1' | '$2'].
tends -> tend_spec : ['$1'].

tend_spec -> 'tend' tend_target ident : {tend, line('$1'), '$2', value('$3')}.
tend_target -> ident : {small, value('$1')}.
tend_target -> name : {great, value('$1')}.

completion_rule -> '$empty' : undefined.
completion_rule -> 'completes' 'when' words : {completes, line('$1'), '$3'}.

words -> ident words : [value('$1') | '$2'].
words -> ident : [value('$1')].

%%--------------------------------------------------------------------
%% Ritul
%%--------------------------------------------------------------------

rite_decl -> 'rite' ident '(' params ')' '->' body 'end' :
    {rite, line('$1'), value('$2'), '$4', '$7'}.

%%--------------------------------------------------------------------
%% Corpuri
%%--------------------------------------------------------------------

body -> stmts terminator : {body, '$1', '$2'}.
body -> terminator : {body, [], '$1'}.

stmts -> stmt stmts : ['$1' | '$2'].
stmts -> stmt : ['$1'].

stmt -> ident '<-' expr : {bind, line('$1'), value('$1'), '$3'}.
stmt -> 'offer' message 'to' expr : {offer, line('$1'), '$2', '$4'}.
stmt -> 'let' ident '=' expr : {'let', line('$1'), value('$2'), '$4'}.
stmt -> 'for' 'each' ident 'in' expr '->' stmts 'end' :
    {foreach, line('$1'), value('$3'), '$5', '$7'}.
stmt -> 'await' name 'completion' 'within' duration :
    {await, line('$1'), value('$2'), value('$5')}.

message -> ident '(' args ')' : {call, line('$1'), value('$1'), '$3'}.
message -> ident : {call, line('$1'), value('$1'), []}.

terminator -> 'keep' : {keep, line('$1')}.
terminator -> 'completion' 'merging' expr 'into' ident :
    {completion, line('$1'), '$3', value('$5')}.
terminator -> 'release' 'quietly' : {release, line('$1'), quietly, undefined}.
terminator -> 'release' 'quietly' 'giving' expr : {release, line('$1'), quietly, '$4'}.
terminator -> 'release' 'withholding' expr : {release, line('$1'), withholding, '$3'}.
terminator -> 'answer' expr : {answer, line('$1'), '$2'}.

%%--------------------------------------------------------------------
%% Expresii -- stratificate, fara declaratii de precedenta
%%--------------------------------------------------------------------

expr -> term '+' expr : {add, line('$2'), '$1', '$3'}.
expr -> term : '$1'.

term -> 'intuit' ident 'with' term : {intuit, line('$1'), value('$2'), '$4'}.
term -> 'reflect' ident : {reflect, line('$1'), value('$2')}.
term -> 'birth' name 'into' name 'with' '(' args ')' :
    {birth, line('$1'), value('$2'), value('$4'), '$7'}.
term -> qualified : '$1'.
term -> call : '$1'.
term -> name '.' ident : {reach, line('$1'), value('$1'), value('$3')}.
term -> ident : {var, line('$1'), value('$1')}.
term -> literal : '$1'.

%% `tensor' e si tip (`tensor[256]'), si spatiu de nume (`tensor.origin(256)').
%% Nu e o ambiguitate, e acelasi concept vazut din doua pozitii: un tip, si un
%% constructor de valori de acel tip. Pozitia in gramatica le distinge --
%% dupa `tensor', un `[' inseamna tip, un `.' inseamna constructie.
qualified -> 'tensor' '.' ident '(' args ')' :
    {builtin, line('$1'), tensor, value('$3'), '$5'}.
qualified -> ident '.' ident '(' args ')' :
    {builtin, line('$1'), value('$1'), value('$3'), '$5'}.

call -> ident '(' args ')' : {call, line('$1'), value('$1'), '$3'}.

args -> expr ',' args : ['$1' | '$3'].
args -> expr : ['$1'].

params -> param ',' params : ['$1' | '$3'].
params -> param : ['$1'].

param -> ident ':' type : {param, line('$1'), value('$1'), '$3'}.
param -> ident : {param, line('$1'), value('$1'), undefined}.

type -> 'text' : text.
type -> 'count' : count.
type -> 'tensor' '[' int ']' : {tensor, value('$3')}.
type -> 'list' 'of' type : {list, '$3'}.

literal -> int : {lit, line('$1'), value('$1')}.
literal -> float : {lit, line('$1'), value('$1')}.
literal -> string : {lit, line('$1'), value('$1')}.
literal -> 'void' : {lit, line('$1'), void}.

Erlang code.

line({_, Line}) -> Line;
line({_, Line, _}) -> Line.

value({_, _, Value}) -> Value;
value({Value, _}) -> Value.
