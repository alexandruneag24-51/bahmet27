%%%-------------------------------------------------------------------
%%% @doc bahmet_vault_sup -- Calea Vietii 9, cu mana de Cal de Foc.
%%%
%%% ═══════════════════════════════════════════════════════════════════
%%%  PARADOXUL PROFILULUI, REZOLVAT IN COD
%%% ═══════════════════════════════════════════════════════════════════
%%%
%%% Profilul cere doua lucruri care par sa se bata cap in cap:
%%% generozitatea Caii Vietii 9 si controlul executiv al Calului de Foc.
%%%
%%% Rezolvarea nu e un compromis intre ele. E o distinctie:
%%%
%%%     Ingaduitor cu cei care gresesc.
%%%     Neinduplecat cu temelia pe care stau toti.
%%%
%%% Generozitatea aplicata uniform nu e virtute, e neglijenta. Un sistem
%%% care iarta la fel de usor o cadere de logare si o sursa de entropie
%%% rupta nu e generos -- e incapabil sa distinga ce conteaza.
%%%
%%% Fiecare copil primeste alta cantitate de iertare, iar cantitatea e
%%% invers proportionala cu cat de scump e sa gresesti acolo. Asta apare
%%% ca `intensity' diferit pe fiecare nivel, si e in acelasi timp
%%% principiul de securitate „fail-closed pe criptografie, fail-open pe
%%% comoditate". Concordanta nu e intamplatoare: si morala, si ingineria
%%% raspund la aceeasi intrebare -- unde e prea scump sa gresesti?
%%%
%%% ═══════════════════════════════════════════════════════════════════
%%%  DE CE `rest_for_one`: ORDINEA ESTE IERARHIA DE INCREDERE
%%% ═══════════════════════════════════════════════════════════════════
%%%
%%%   bahmet_entropy ─► bahmet_dek_store ─► bahmet_keyring ─► bahmet_rotation ─► bahmet_sentinel
%%%   (sursa)           (starea durabila)   (custodia)         (igiena)            (observatorul)
%%%
%%% Cade entropia  -> cad TOTI. Cheile generate dupa o sursa suspecta sunt
%%%                   suspecte, iar cei care le tin nu au cum sa afle singuri.
%%% Cade custodia  -> cad rotatia si santinela (handle-uri moarte), sursa nu.
%%% Cade santinela -> nu cade nimeni. Un paznic care opreste tot cand se
%%%                   impiedica e mai periculos decat lipsa lui.
%%%
%%% Perspectiva globala inseamna exact aceasta cunoastere: cine depinde de
%%% cine. Niciun copil nu o are; supervizorul o are si o executa.
%%% @end
%%%-------------------------------------------------------------------
-module(bahmet_vault_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-define(SERVER, ?MODULE).

%% Ragazul de plecare. Un custode primeste timp sa-si incheie operatiile
%% in curs si sa-si sterga starea inainte de a fi oprit. `brutal_kill' ar
%% lasa secrete nesterse in memorie -- autoritatea executiva nu inseamna
%% grabire, inseamna ca plecarea nu se negociaza.
-define(GRACE, 5000).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->

    SupFlags = #{
        strategy  => rest_for_one,

        %% Toleranta la nivelul radacinii. Trei caderi in 60 de secunde
        %% inseamna ca problema nu e tranzitorie. Atunci supervizorul face
        %% lucrul greu: renunta la propria autoritate si preda situatia unei
        %% vederi mai largi, in loc sa reporneasca la infinit si sa ascunda
        %% cauza reala de sub ochii tuturor.
        %%
        %% Asta e smerenia Caii Vietii 9 codificata: a recunoaste ca
        %% perspectiva ta, oricat de globala, tot e marginita.
        intensity => 3,
        period    => 60,

        auto_shutdown => never
    },

    %% ── 1. ENTROPIA — ZERO IERTARE ──────────────────────────────────
    %%
    %% Singurul copil cu `intensity' zero la nivelul lui propriu (vezi
    %% bahmet_entropy: refuza sa porneasca daca sursa e degradata, iar
    %% pozitia lui aici face ca refuzul sa opreasca tot).
    %%
    %% Nu degradam elegant. O cheie generata din entropie proasta e o iluzie
    %% de securitate -- mai rea decat lipsa ei, fiindca produce incredere
    %% nemeritata. Aici generozitatea ar fi cruzime deghizata: ai lasa
    %% oamenii sa creada ca datele lor sunt protejate cand nu sunt.
    %%
    %% `permanent' + primul in ordine = daca pica, tot ce s-a construit pe
    %% el se refondeaza. Nu exista scenariu in care sistemul merge mai
    %% departe fara sursa verificata.
    Entropy = #{
        id       => bahmet_entropy,
        start    => {bahmet_entropy, start_link, []},
        restart  => permanent,
        shutdown => ?GRACE,
        type     => worker,
        modules  => [bahmet_entropy]
    },

    %% ── 2. CUSTODIA — IERTARE MINIMA ────────────────────────────────
    %%
    %% Detine cheia radacina, injectata din exterior. Nu o persista
    %% niciodata. Daca pica, handle-urile pe care le-a impartit devin
    %% orfane -- de aceea rotatia si santinela, care vin dupa, se
    %% refondeaza odata cu el.
    Keyring = #{
        id       => bahmet_keyring,
        start    => {bahmet_keyring, start_link, []},
        restart  => permanent,
        shutdown => ?GRACE,
        type     => worker,
        modules  => [bahmet_keyring]
    },

    %% ── 3. DEPOZITUL — IERTARE MICA ─────────────────────────────────
    %%
    %% Catalogul DEK-urilor, pe disc. Sta INAINTEA rotatiei fiindca rotatia
    %% nu are ce itera fara el, si DUPA custodie fiindca aici se persista
    %% generatia curenta pe care keyring-ul o citeste la pornire.
    %%
    %% Asteapta: keyring-ul citeste `generation()' din depozit la `init'.
    %% Deci depozitul trebuie sa fie deja viu -- vezi ordinea reala mai jos.
    Store = #{
        id       => bahmet_dek_store,
        start    => {bahmet_dek_store, start_link, []},
        restart  => permanent,
        shutdown => ?GRACE,
        type     => worker,
        modules  => [bahmet_dek_store]
    },

    %% ── 4. ROTATIA — IERTARE MODERATA ───────────────────────────────
    %%
    %% Igiena periodica: KEK nou, reimpachetarea DEK-urilor, distrugerea
    %% celui vechi. O rotatie intrerupta la mijloc nu e o catastrofa,
    %% fiindca e idempotenta prin numarul de generatie: repornirea reia de
    %% unde a ramas, nu strica ce s-a facut.
    %%
    %% De aceea isi poate permite sa fie iertata. Nu din bunatate --
    %% din faptul ca greseala ei e recuperabila.
    Rotation = #{
        id       => bahmet_rotation,
        start    => {bahmet_rotation, start_link, []},
        restart  => permanent,
        shutdown => ?GRACE,
        type     => worker,
        modules  => [bahmet_rotation]
    },

    %% ── 5. SANTINELA — CEA MAI IERTATA ──────────────────────────────
    %%
    %% `transient', ultima in ordine, si deliberat NEESENTIALA.
    %%
    %% Un observator care poate opri sistemul cand se impiedica e mai
    %% periculos decat lipsa observatorului: devine un vector de
    %% indisponibilitate pe care un atacator il poate declansa intentionat.
    %% Daca santinela cade, seiful continua sa functioneze -- orb, dar viu.
    %%
    %% Fiind ultima in `rest_for_one', caderea ei nu atinge pe nimeni.
    %% Asta e generozitatea in forma ei cea mai utila: sa nu-ti faci
    %% propriul paznic o dependenta critica.
    Sentinel = #{
        id       => bahmet_sentinel,
        start    => {bahmet_sentinel, start_link, []},
        restart  => transient,
        shutdown => ?GRACE,
        type     => worker,
        modules  => [bahmet_sentinel]
    },

    %% ORDINEA E GRAFUL DE DEPENDENTA, nu ordinea in care le-am scris:
    %% entropia sustine totul; depozitul e starea durabila; custodia se
    %% RECONSTRUIESTE din radacina plus generatia citita din depozit; rotatia
    %% are nevoie de amandoua; santinela de niciuna.
    {ok, {SupFlags, [Entropy, Store, Keyring, Rotation, Sentinel]}}.
