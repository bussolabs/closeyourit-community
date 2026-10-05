# frozen_string_literal: true

module Ticketing
  # Costanti del dominio ticketing (rules/constants.md).
  module Constants
    # Finestra "chiusi di recente" dei candidati duplicato: un ticket chiuso oltre questa soglia non
    # è più un candidato (probabile regressione nuova, non doppione). Gli aperti/in lavorazione/in
    # review sono candidati sempre. Era 90 giorni quando la lista serviva solo al confronto al
    # salvataggio; ora la stessa scope alimenta anche il pannello del form, dove chi scrive deve
    # poter spuntare quello che vede — e un lavoro chiuso tre mesi fa non è più il lavoro a cui
    # agganciare quello nuovo.
    DUPLICATE_CLOSED_WINDOW = 30.days

    # Le due soglie del suggerimento duplicati (CYRA-633), in SOMIGLIANZA percentuale e non in distanza.
    #
    # La scala nativa è la distanza coseno di pgvector: 0 = testi identici, 1 = nessuna parentela.
    # La somiglianza che si legge in pagina è il suo complemento, e la conversione sta in un posto
    # solo (Embeddings::Similarity). Le soglie vivono qui in percentuale perché è la forma in cui si
    # decide: "sopra il 90%" è una frase che si può discutere, "sotto 0.10 di distanza" no — e
    # nessun 0.20/0.10 va scritto altrove, né in app né nelle prove.
    #
    # La soglia unica precedente valeva 0.45 di distanza, cioè il 55% di somiglianza: bastava un tema
    # vicino per fermare la creazione con una pagina di confronto, e quei falsi positivi erano il
    # passaggio di troppo. Ora sono due numeri diversi perché rispondono a due domande diverse: cosa
    # vale la pena MOSTRARE mentre si scrive, e cosa vale la pena FERMARE.
    #
    # Sono più stretti di prima e vanno guardati sui dati veri: se il pannello resta muto o il
    # confronto non compare mai, si correggono qui e in nessun altro posto.
    DUPLICATE_PANEL_SIMILARITY = 80
    DUPLICATE_GATE_SIMILARITY = 90

    # Tetto di lunghezza del corpo semplice e del registro tecnico, gemelli di
    # Knowledge::Constants::{BODY,TECH_SPEC}_MAX_CHARS (stessi numeri: la regola è una sola, "un
    # ticket si legge in tre minuti"). Come per le pagine il vincolo è anche di ricerca —
    # Ticketing::EmbeddingText finisce sotto il clamp di Ai::Constants::EMBED_MAX_CHARS — ma qui la
    # garanzia NON è dimostrabile: il testo embeddato include anche gli scenari BDD, che sono record
    # separati e senza tetto. Il caso residuo lo copre il warning di Embeddings::EmbedText, che
    # rende il taglio visibile nei log invece che silenzioso.
    DESCRIPTION_MAX_CHARS = 4_000
    TECHNICAL_ANALYSIS_MAX_CHARS = 1_500

    # Bersaglio dell'analisi tecnica: quanto DOVREBBE essere lunga, non quanto PUÒ (CYRA-263). Due
    # numeri e non uno perché rispondono a due domande diverse, e con il solo tetto vince sempre il
    # tetto: prima di questa costante le ultime dieci analisi misuravano 1.417, 1.462, 1.483, 1.444,
    # 1.483 e 1.498 su 1.500. Chi scrive riempie lo spazio che gli si dà.
    #
    # Non è una quota di TECHNICAL_ANALYSIS_MAX_CHARS (App::Constants::LENGTH_WARN_RATIO resta il
    # default degli altri campi): l'80% del tetto sarebbe 1.200, cioè un avviso che arriva quando il
    # testo è già scritto e accorciarlo significa riscriverlo. 900 è la misura in cui le quattro
    # etichette di knowledge-base/global/closeyourit-writing.md ci stanno senza raccontare.
    #
    # Superarlo NON è un errore e non blocca niente: il tetto resta l'unica cosa che il model
    # rifiuta. Qui si colora un contatore.
    TECHNICAL_ANALYSIS_TARGET_CHARS = 900

    # Tetto di un commento di TICKET (CYRA-222). Il testo lungo ha un posto suo: il resoconto di
    # lavorazione (REPORT_MAX_CHARS, CYRA-220), quindi qui il messaggio breve è una scelta, non una
    # strettoia.
    #
    # Valeva anche per i commenti delle idee, sull'argomento che un commento è lo stesso oggetto in
    # due namespace; CYRA-371 ha separato i due tetti perché l'oggetto è lo stesso ma il ruolo no:
    # su un'idea il commento è il luogo in cui si argomenta una decisione, e non ha nessun resoconto
    # a fianco dove mettere il testo lungo. Vedi Ideas::Constants::COMMENT_MAX_CHARS.
    COMMENT_MAX_CHARS = 240

    # Tetto di una DOMANDA e di una RISPOSTA (CYRA-779). Lo stesso del commento, e per la stessa
    # ragione: una domanda che non sta in due righe non è una domanda, è un capitolo del resoconto.
    # Sono due costanti e non un alias perché il giorno che una risposta avrà bisogno di più spazio —
    # è l'ipotesi più probabile: chi risponde spesso deve spiegare — si alza quella, non il tetto
    # della discussione.
    QUESTION_MAX_CHARS = COMMENT_MAX_CHARS
    ANSWER_MAX_CHARS = COMMENT_MAX_CHARS

    # Tetto delle domande poste da un AGENTE. Più stretto, e non è una scelta di stile: 180 è il
    # numero scritto nel contratto verso gli host (agent-clarification/v1) e ricopiato in
    # closeyourit-automator (MAX_CLARIFICATION_QUESTION_LENGTH). Accettare qui più di quanto quel
    # gemello lascia passare farebbe entrare domande che il lettore esterno rifiuta; accettarne meno
    # farebbe rifiutare consegne di triage valide, e una consegna rifiutata è una lavorazione che
    # riprova all'infinito.
    AGENT_QUESTION_MAX_CHARS = 180

    # Tetto del resoconto di lavorazione (CYRA-220). Molto più alto dei due qui sopra e per un motivo
    # opposto: un resoconto NON si legge in tre minuti, è un registro tecnico che si consulta, e non
    # finisce in un embedding (nessun vincolo di Ai::Constants::EMBED_MAX_CHARS). Il più lungo dei 562
    # commenti migrati misura 7.624 caratteri: il tetto lascia margine e serve solo a fermare un agente
    # che provi a scaricare qui dentro un diff intero.
    REPORT_MAX_CHARS = 20_000

    # Tetto della motivazione con cui si respinge un lavoro consegnato (CYRA-389). NON è quello del
    # commento: 240 caratteri sono la misura di un messaggio breve, e chi respinge scrive la cosa più
    # importante del gesto — l'agente che ha consegnato ne ha scritti quattromila, chi giudica ne
    # aveva 240. Prima di questa costante il testo oltre soglia non veniva rifiutato: veniva perso in
    # un warn nei log, con la motivazione ferma nel jsonb dell'evento che nessuna pagina mostra.
    #
    # È lo STESSO numero del resoconto, e riferito e non ricopiato di proposito: oltre il tetto del
    # commento la motivazione viene scritta nel resoconto (Ticketing::RejectReview), quindi il tetto
    # è quello del posto in cui finisce. Due numeri gemelli potrebbero divergere e il guard del
    # service accetterebbe testo che il resoconto rifiuta.
    REVIEW_REASON_MAX_CHARS = REPORT_MAX_CHARS

    # Quanti commenti al minuto accoda la compattazione (CYRA-222). Stesso numero e stessa ragione di
    # AGENT_ELIGIBILITY_BACKFILL_PER_MINUTE: il tetto non è il nostro throughput ma il rate limit del
    # provider, che al primo backfill reale ha risposto 429 per 327 volte di fila. Con 562 commenti
    # storici fanno circa 70 minuti — un'attesa accettabile per un'operazione che si fa una volta.
    COMMENT_COMPACTION_PER_MINUTE = 8

    # Quanto possono distare due commenti dello stesso autore per essere letti come UN testo solo
    # spezzato in due, e non come due interventi distinti (CYRA-260). Chi scriveva un'analisi lunga la
    # tagliava e incollava il resto subito dopo: nei dati storici il secondo pezzo arriva entro pochi
    # minuti dal primo. Quindici minuti tengono dentro anche la pausa di chi rilegge prima di
    # incollare, e restano ben sotto il ritmo di una discussione vera, dove fra due interventi passano
    # ore.
    ANALYSIS_RECOMPOSE_WINDOW = 15.minutes

    # Quanto deve essere pieno il campo analisi perché un commento lungo scritto dopo sia la sua
    # CONTINUAZIONE e non un intervento a sé (CYRA-260).
    #
    # Non è una soglia scelta a occhio, è la firma del fenomeno nei dati. Sui 749 ticket con commenti
    # lunghi la lunghezza dell'analisi cala in modo regolare (307 ticket entro 250 caratteri, poi 193,
    # 83, 46, 30) e poi RISALE a 70 nella fascia 1250-1499: gente che ha scritto finché il campo si è
    # riempito. Tutti i commenti che si dichiarano da soli "analisi tecnica estesa (il campo dedicato
    # ha un limite di 1500 caratteri)" stanno su ticket con il campo fra 1.383 e 1.491.
    #
    # Frazione e non numero fisso: la regola è "il campo era pieno", e resta vera se il tetto cambia.
    ANALYSIS_SATURATION_RATIO = 0.93

    # --- Gate di eleggibilità agenti (CYRA-184) ---------------------------------------------------

    # Tetti degli allegati spediti inline al server AI per la valutazione. Il vincolo duro è il limite
    # di 20 MB per RICHIESTA (prompt inclusi): con ATTACHMENT_MAX_SIZE a 10 MB e l'inflazione
    # base64 (+33%) due soli allegati grandi lo sfonderebbero. Si contano i byte GREZZI, pre-base64.
    AGENT_ELIGIBILITY_MAX_INLINE_ATTACHMENTS = 6
    AGENT_ELIGIBILITY_MAX_INLINE_BYTES = 6.megabytes
    # I text/plain non viaggiano come binario ma inlinati nel prompt: più economici e più affidabili.
    AGENT_ELIGIBILITY_MAX_INLINE_TEXT_CHARS = 4_000

    # Tipi che il gateway vision (Qwen via Proxanything) sa davvero leggere. NON è
    # App::Constants::ATTACHMENT_CONTENT_TYPES meno qualcosa:
    #  - `image/gif` è accettato come allegato ma non è un formato vision supportato;
    #  - `application/pdf` lo leggeva il fornitore di allora, questo no.
    # Ciò che resta fuori non viene ignorato in silenzio: finisce nell'elenco degli allegati NON
    # analizzati dichiarato nel prompt, così un ticket che rimanda a materiale invisibile al modello
    # diventa un caso di `underspecified` invece di un punto cieco.
    AGENT_ELIGIBILITY_INLINE_IMAGE_TYPES = %w[image/png image/jpeg image/webp].freeze
    AGENT_ELIGIBILITY_INLINE_TEXT_TYPES = %w[text/plain].freeze

    # Debounce dell'enqueue: chi salva cinque volte in mezzo minuto accoda cinque job che partono
    # tutti dopo il testo definitivo, e la guardia sul checksum ne fa lavorare uno solo.
    AGENT_ELIGIBILITY_DEBOUNCE = 30.seconds

    # Quanti ticket al minuto accoda il backfill. Il tetto NON è il nostro throughput ma il rate
    # limit del fornitore: al primo backfill reale (169 ticket in una volta) il fornitore di allora ha
    # risposto 429 e sono stati prodotti 7 verdetti su 169. Meglio un backfill lento che uno che
    # fallisce — e il server AI di casa serve quattro richieste per volta, poi mette in coda.
    AGENT_ELIGIBILITY_BACKFILL_PER_MINUTE = 8

    # Tetto per giro del recupero automatico dei pareri mancanti (CYRA-847). Il giro è orario, quindi
    # il tetto è anche il ritmo con cui si smaltisce un arretrato: 40 all'ora drenano in circa due
    # giorni e mezzo i 2.372 ticket rimasti senza parere in cinque settimane di guasto, senza mai
    # chiedere al server AI più di quanto gli chieda una giornata di lavoro normale. Un giro SENZA
    # tetto, sullo stesso arretrato, sarebbe una raffica di 2.372 chiamate: il rate limit la punisce
    # e il recupero non si fa — è esattamente com'è andata al primo backfill in produzione.
    AGENT_ELIGIBILITY_RECOVERY_PER_RUN = 40

    # Budget di output del verdetto: un oggetto con motivazione discorsiva. Più alto del default
    # della chat perché un troncamento qui non dà testo parziale ma JSON invalido.
    AGENT_ELIGIBILITY_MAX_TOKENS = 2048

    # --- Snapshot del contesto di lavoro (CYRA-76) ------------------------------------------------

    # Versione dello SCHEMA del payload di Ticketing::WorkContextSnapshot (references + procedures
    # risolte). Non è un contatore per ticket: avanza solo se cambia la FORMA del payload, così un
    # lettore d'audit sa come interpretarlo. Finisce anche nel digest.
    WORK_CONTEXT_PAYLOAD_VERSION = 1

    # --- Board Kanban (CYRA-390) ------------------------------------------------------------------

    # Primo blocco di card renderizzate per colonna della board: oltre questo la colonna offre
    # «mostra altre» (append incrementale via Member::TicketsController#column), invece di riversare
    # in pagina l'intera colonna. Il caso limite era `Resolved 931`: 116 KB di sole card concluse,
    # gran parte del peso della board e inutili a qualsiasi decisione. Il conteggio in intestazione
    # resta il TOTALE reale, non le card mostrate — la finestra riguarda ciò che si vede, non i numeri.
    BOARD_COLUMN_PAGE = 20

    # Finestra temporale di default delle colonne di lavoro CONCLUSO (status category `done`): la
    # board ne mostra solo gli ultimi giorni, dichiarati nell'intestazione della colonna, filtrando
    # per `closed_at`. Lo storico completo di uno stato concluso resta raggiungibile dalla vista
    # lista filtrata per stato. Le colonne aperte/in corso non hanno finestra (sono il lavoro vivo).
    BOARD_DONE_WINDOW = 7.days

    # CYRA-901 — filters that board and list both understand: the Board | List switch carries these
    # and drops the rest (status is the board's column axis, sort and page are list-only).
    VIEW_SHARED_FILTERS = %w[kind project_id group_id priority_id assignee_id reviewer_id
                             agent_eligibility awaiting questions q semantic].freeze

    # CYRA-901 — the board card's priority arrow, by priority code; a custom code falls back to a flag.
    PRIORITY_ICONS = { "high" => "arrow-up", "medium" => "equal", "low" => "arrow-down" }.freeze
  end
end
