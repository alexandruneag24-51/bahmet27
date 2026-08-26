%%%-------------------------------------------------------------------
%%% Bahmet 27 -- analizorul sintactic (yecc).
%%%
%%% NOTA DE PROIECTARE: numele neterminalelor nu au voie sa coincida cu
%%% cuvintele-cheie. In Erlang, `circle' si `'circle'' sunt acelasi atom,
%%% deci un neterminal numit `circle' l-ar ciocni pe terminalul `'circle''.
%%% De aici sufixele `_decl' si `_clause', si radacina numita `unit'.
%%%
%%% Adunarea e stratificata (`expr -> term '+' expr') in loc sa foloseasca
%%% declaratii de precedenta. Gramatica devine putin mai lunga si complet
%%% neambigua -- fara conflicte de rezolvat si fara reguli tacite de
%%% asociativitate pe care cititorul ar trebui sa le tina minte.
%%%-------------------------------------------------------------------

Nonterminals
unit decls decl
ground_decl settings setting commons_decl being_decl
carries_block fields field attrs attr
clauses clause awaken_clause upon_clause broken_clause
body stmts stmt terminator
expr term call args params param type literal.

Terminals
'circle' 'being' 'carries' 'end'
'patience' 'grace'
'awaken' 'with' 'upon' 'from'
'keep' 'completion' 'merging' 'into'
'release' 'quietly' 'giving' 'withholding'
'when' 'broken'
'offer' 'to' 'intuit'
'commons' 'ground'
'text' 'count' 'tensor' 'void'
'<-' '->' ':' ',' '(' ')' '[' ']' '=' '+'
ident name int float string duration.

Rootsymbol unit.

unit -> 'circle' name decls 'end' : {circle, line('$1'), value('$2'), '$3'}.

decls -> decl decls : ['$1' | '$2'].
decls -> decl : ['$1'].

decl -> ground_decl : '$1'.
decl -> commons_decl : '$1'.
decl -> being_decl : '$1'.

ground_decl -> 'ground' ident settings 'end' :
    {ground, line('$1'), value('$2'), '$3'}.

settings -> setting settings : ['$1' | '$2'].
settings -> setting : ['$1'].
setting -> ident int : {value('$1'), value('$2'), line('$1')}.

commons_decl -> 'commons' ident ':' type :
    {commons, line('$1'), value('$2'), '$4'}.

being_decl -> 'being' name carries_block attrs clauses 'end' :
    {being, line('$1'), value('$2'), '$3', '$4', '$5'}.

carries_block -> 'carries' fields 'end' : '$2'.

fields -> field fields : ['$1' | '$2'].
fields -> field : ['$1'].

field -> ident ':' type : {field, line('$1'), value('$1'), '$3', undefined}.
field -> ident ':' type '=' literal : {field, line('$1'), value('$1'), '$3', '$5'}.

%% Atributele si clauzele pot lipsi din gramatica, DELIBERAT. O fiinta fara
%% `patience' sau fara `when broken' trebuie sa produca o eroare de invariant
%% care spune ce lipseste si de ce, nu un „syntax error" care spune doar unde.
attrs -> '$empty' : [].
attrs -> attr attrs : ['$1' | '$2'].

attr -> 'patience' duration : {attr, line('$1'), patience, value('$2')}.
attr -> 'grace' duration : {attr, line('$1'), grace, value('$2')}.

clauses -> '$empty' : [].
clauses -> clause clauses : ['$1' | '$2'].

clause -> awaken_clause : '$1'.
clause -> upon_clause : '$1'.
clause -> broken_clause : '$1'.

awaken_clause -> 'awaken' 'with' '(' params ')' '->' body 'end' :
    {awaken, line('$1'), '$4', '$7'}.

upon_clause -> 'upon' ident '(' params ')' 'from' ident '->' body 'end' :
    {upon, line('$1'), value('$2'), '$4', value('$7'), '$9'}.
upon_clause -> 'upon' ident '(' params ')' '->' body 'end' :
    {upon, line('$1'), value('$2'), '$4', undefined, '$7'}.
upon_clause -> 'upon' ident '->' body 'end' :
    {upon, line('$1'), value('$2'), [], undefined, '$4'}.

broken_clause -> 'when' 'broken' '->' body 'end' :
    {broken, line('$1'), '$4'}.

body -> stmts terminator : {body, '$1', '$2'}.
body -> terminator : {body, [], '$1'}.

stmts -> stmt stmts : ['$1' | '$2'].
stmts -> stmt : ['$1'].

stmt -> ident '<-' expr : {bind, line('$1'), value('$1'), '$3'}.
stmt -> 'offer' call 'to' expr : {offer, line('$1'), '$2', '$4'}.

terminator -> 'keep' : {keep, line('$1')}.
terminator -> 'completion' 'merging' expr 'into' ident :
    {completion, line('$1'), '$3', value('$5')}.
terminator -> 'release' 'quietly' : {release, line('$1'), quietly, undefined}.
terminator -> 'release' 'quietly' 'giving' expr : {release, line('$1'), quietly, '$4'}.
terminator -> 'release' 'withholding' expr : {release, line('$1'), withholding, '$3'}.

expr -> term '+' expr : {add, line('$2'), '$1', '$3'}.
expr -> term : '$1'.

term -> 'intuit' ident 'with' term : {intuit, line('$1'), value('$2'), '$4'}.
term -> call : '$1'.
term -> ident : {var, line('$1'), value('$1')}.
term -> literal : '$1'.

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

literal -> int : {lit, line('$1'), value('$1')}.
literal -> float : {lit, line('$1'), value('$1')}.
literal -> string : {lit, line('$1'), value('$1')}.
literal -> 'void' : {lit, line('$1'), void}.

Erlang code.

line({_, Line}) -> Line;
line({_, Line, _}) -> Line.

value({_, _, Value}) -> Value;
value({Value, _}) -> Value.
