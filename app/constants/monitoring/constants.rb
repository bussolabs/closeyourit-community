# frozen_string_literal: true

module Monitoring
  # Costanti che errori e metriche condividono (rules/constants.md): sono due domini distinti ma una
  # sola forma — un gruppo, le sue occorrenze, la pagina che le mostra — e le regole scritte qui
  # valgono per entrambi. Quello che invece è di uno solo (retention, tetti d'ingest, spike) sta in
  # Errors::Constants e Metrics::Constants.
  module Constants
    # Occorrenze nella show di monitoring (error group events + metric group samples): pagina densa
    # ma limitata, così una issue con migliaia di occorrenze non renderizza una lista sconfinata.
    OCCURRENCES_PER_PAGE = 15

    # CYRA-400 — quante occorrenze si MOSTRANO di quella pagina prima di chiedere di vederle tutte.
    # Su un gruppo tipico le quindici righe erano identiche salvo l'identificativo dell'evento: la
    # sezione più grande della pagina era quella che diceva meno. Cinque bastano per riconoscere il
    # ritmo con cui l'errore si ripete; il resto sta dietro un comando.
    OCCURRENCES_COLLAPSED = 5

    # CYRA-566 — quanti passaggi dello stacktrace si mostrano prima di chiudere i restanti dietro un
    # comando. La lista è invertita (il punto del guasto in cima), quindi il taglio toglie SEMPRE i
    # chiamanti più esterni: proprio quelli che dicono da dove è partita la chiamata. Il taglio resta
    # perché i pannelli sono uno per occorrenza mostrata, ma ora è dichiarato e apribile.
    STACKTRACE_COLLAPSED = 20

    # Throttle del page-refresh Turbo realtime del monitoring (errori/metriche), per stream (lista org e
    # singola show). Sotto burst d'ingest l'aggiornamento realtime è coalescente: un solo refresh cable
    # per finestra invece di due aggregazioni org-wide + tre broadcast per campione (CYRA-41). "~1/sec
    # per org" come da analisi del ticket; Turbo 8 debounce comunque i refresh lato client.
    BROADCAST_THROTTLE = 1.second

    # CYRA-822 — quanti progetti selezionati insieme valgono ancora una sottoscrizione per progetto
    # al segnale di aggiornamento della lista. Oltre questo tetto la pagina torna al segnale unico
    # dell'organizzazione: le sottoscrizioni sono connessioni aperte per ogni sessione, e sopra un
    # certo numero costano più del lavoro che evitano — a maggior ragione perché chi seleziona
    # mezza organizzazione riceverebbe comunque quasi tutti i segnali.
    #
    # Dieci è generoso rispetto all'uso reale (si filtra su uno o due progetti) e resta un numero
    # basso di connessioni per sessione. Sopra, il comportamento è quello di sempre: un solo stream,
    # nessun aggiornamento perso.
    LIST_STREAM_PROJECT_CAP = 10

    # Tetto per GRUPPO alle occorrenze di telemetria conservate per intero — vale sia per gli errori
    # (`Errors::Ingest::Record`) sia per le metriche (`Metrics::Ingest::Record`): stessa forma, stesso
    # rischio. Il throttle rack-attack è per PROGETTO (600/min = 36k/h), quindi una raffica di un solo
    # fingerprint ci passa sotto: il 2026-07-29 sono stati 278.543 eventi identici in dieci ore contro
    # le ~200/giorno normali, 8,6 GB di payload e il disco di sentinel all'86%.
    #
    # Oltre questa soglia l'occorrenza si conserva ancora — la RIGA c'è sempre — ma **senza il corpo**:
    # payload, stacktrace e contesto vengono lasciati vuoti. Quei tre campi jsonb sono il 99% del peso
    # (gli 8,6 GB erano payload, non righe: 278.543 righe spoglie stanno in meno di cento megabyte).
    #
    # Tenere la riga e buttare il corpo, invece di buttare la riga, non è un dettaglio: la riga è ciò
    # su cui poggiano l'idempotenza (`event_id` / `sample_id` unici → un delivery ripetuto non ri-conta),
    # il conteggio degli utenti distinti, e la rilevazione degli spike, che conta le OCCORRENZE per
    # bucket temporale. Campionare le righe avrebbe rotto tutte e tre per risparmiare un centesimo in
    # più di spazio.
    TELEMETRY_FULL_FIDELITY_COUNT = 5_000

    # Un gruppo è "caldo" se l'occorrenza precedente è arrivata entro questo intervallo: è la misura di
    # una raffica IN CORSO, distinta da "gruppo con molte occorrenze in totale".
    #
    # La differenza conta. `events_count` è cumulativo: un errore cronico che accumula cinquemila
    # occorrenze in sei mesi non è una raffica, e trattarlo come tale gli spegnerebbe la rilevazione
    # degli spike PER SEMPRE — proprio sul gruppo che un giorno potrebbe esplodere. Il gate sulla
    # scrittura della probe usa quindi "grande E caldo", che è transitorio: un gruppo cronico non è mai
    # caldo, un gruppo in raffica smette di esserlo appena la raffica finisce.
    #
    # Il dato è gratis: `last_seen_at` pre-bump è già in memoria, non serve nessuna query.
    TELEMETRY_BURST_GAP = 5.seconds

    # Durante una raffica, il lavoro per-occorrenza che passa da `Rails.cache` si fa una volta ogni N
    # invece che sempre. `Rails.cache` in produzione è **SQLite**, e i chiamanti sono due: la probe
    # della rilevazione spike (1 scrittura) e il segnale di refresh realtime, che tocca due stream con
    # fino a due scritture ciascuno. Fanno da due a quattro scritture per occorrenza: durante la raffica
    # del 2026-07-29 oltre un milione di tentativi su un file già in lock — ed è proprio quel lock che
    # generava l'errore che stava arrivando.
    #
    # A 7,7 occorrenze/sec (il ritmo misurato di quella raffica) uno ogni cento è un segnale ogni ~13
    # secondi. La finestra di throttle del refresh è di un secondo, quindi la UI resta viva; e la
    # rilevazione dello spike resta possibile, perché le righe ci sono tutte (si butta il corpo, non la
    # riga) e `spiking?` le conta ancora.
    TELEMETRY_BURST_WORK_EVERY = 100
  end
end
