# frozen_string_literal: true

module Servers
  # Costanti del dominio server monitoring (rules/constants.md): l'agent closeyourit-agent push-a le
  # misure di una macchina, e qui stanno le soglie con cui si decide che quella macchina è ferma, che
  # i suoi numeri sono vecchi o che il suo disco sta per finire.
  module Constants
    # Fleet server: densità più alta della tabella standard. Una fleet è piccola e stabile —
    # con App::Constants::TABLE_PER_PAGE (10) host oltre il decimo sparivano in pagina 2; qui stanno in
    # una schermata sola (l'utente vedeva "solo 10 server" con 14 host in flotta).
    PER_PAGE = 50

    # Agent image in the docker-compose snippet: the public one unless the install points elsewhere (CYRA-916).
    AGENT_IMAGE = ENV.fetch("AGENT_IMAGE", "ghcr.io/bussolabs/closeyourit-agent:latest")

    # Inventario database: una macchina ne ospita decine (un progetto = database + coda), quindi la
    # densità standard spezzerebbe in più pagine l'elenco di un solo server. Sotto PER_PAGE
    # perché qui le righe sono i database, non le macchine.
    DATABASES_PER_PAGE = 25

    # Stale dopo 3 push mancati (l'agent push-a ogni 60s) → CheckStaleJob marca down e avvisa.
    STALE_AFTER_SECONDS = 180
    # CYRA-461 — soglia del "silenzio": una macchina che non manda misure da più di questo tempo è
    # ancora up (nessuno l'ha dichiarata giù) ma i suoi numeri sono una fotografia vecchia. Sta a
    # METÀ della soglia di stale: prima che il sistema la marchi giù, chi guarda deve già sapere che
    # sta leggendo un dato fermo. Largo abbastanza da non accendersi su un agent con intervallo lungo
    # (è il rischio dichiarato nel ticket).
    SILENT_AFTER_SECONDS = 90
    # CYRA-676 — soglia dell'ALLARME sul silenzio, distinta di proposito dai 90s del badge: il badge
    # può accendersi e spegnersi al ritmo dell'ingest, un avviso no. Larga abbastanza da scavalcare
    # un arretrato ordinario della corsia dei dati (CYRA-649: i backfill notturni la riempivano per
    # minuti, e una soglia stretta rifarebbe i 76 falsi avvisi al giorno sotto un altro nome): se i
    # dati restano fermi per un quarto d'ora con la macchina che risponde, il fermo è vero.
    SILENT_ALERT_AFTER_SECONDS = 15.minutes.to_i
    # CYRA-775 — per quanto tempo un rifiuto NOSTRO (il backend che risponde «troppe richieste» a un
    # agent) tiene sospeso il giudizio sulla salute delle macchine. Vale STALE_AFTER_SECONDS perché è
    # esattamente il tempo che serve a un rifiuto per diventare un falso guasto: bloccato il push, la
    # macchina attraversa la soglia di staleness dopo quella finestra e non un minuto prima. Si misura
    # dall'ULTIMO rifiuto, quindi un episodio lungo resta coperto per intero più questa coda — il tempo
    # che l'agent ha per rifarsi vivo (push ogni 60s) prima che il silenzio torni a essere suo.
    INGEST_REJECTION_WINDOW_SECONDS = STALE_AFTER_SECONDS
    # Retention dei raw sample: gerarchia god → org (CYRA-159, niente livello progetto — i dati server
    # sono org-scoped nel data model). Container/journal restano buffer diagnostici a costante fissa.
    RETENTION_DEFAULT_DAYS = 30
    CONTAINER_RETENTION_DAYS = 7
    # CYRA-679 — medie orarie scritte dal prune prima del delete dei raw: un anno di baseline costa
    # ~9k righe per host, niente rispetto al raw al minuto.
    ROLLUP_RETENTION_DAYS = 365
    # CYRA-679 — previsione di saturazione del volume dati: regressione sugli ultimi 7 giorni di
    # campioni; avvisa quando la stima ENTRA sotto i 14 giorni, si riarma sopra i 21 (isteresi:
    # una stima che balla intorno alla soglia non deve fare ping-pong di avvisi).
    DISK_FORECAST_WINDOW_DAYS = 7
    DISK_FORECAST_ALERT_DAYS = 14
    DISK_FORECAST_CLEAR_DAYS = 21
    DISK_FORECAST_MIN_POINTS = 48
    # Log nativi journald (stream err/crit): finestra breve — la diagnosi serve subito, non a lungo.
    # La finestra UX esatta la garantisce la query della show; il prune daily può lasciare code < 72h.
    JOURNAL_RETENTION_HOURS = 48
    # Payload agent oltre questo limite → R413 (un CombinedData reale sta ampiamente sotto 1 MB).
    MAX_PAYLOAD_BYTES = 1.megabyte
    TOKEN_PREFIX = "cyi_s_"
    # CYRA-809 — quanto silenzio serve, oltre la scadenza della lease, prima di dichiarare INTERROTTA
    # un'azione operativa partita e mai conclusa. La lease dura due minuti (Actions::Claim::LEASE) e
    # nessuno la rinnova mentre il comando gira: la sua scadenza da sola non prova che il comando sia
    # finito, e un'installazione di aggiornamenti la supera senza essere morta. Vale quanto la soglia
    # d'allarme sul silenzio di una macchina: sotto di essa il sistema non si pronuncia ancora su
    # niente, e non deve iniziare a farlo proprio qui, dove sbagliare libera il posto a un secondo
    # comando mentre il primo è vivo. Si misura dalla scadenza della lease, quindi è il tempo minimo
    # di esecuzione tollerato; nel caso ordinario — azione ritirata entro un minuto dalla richiesta —
    # è la finestra di autorizzazione (un'ora) a proteggerla, molto più a lungo.
    ACTION_ORPHAN_AFTER_SECONDS = SILENT_ALERT_AFTER_SECONDS
    # CYRA-245 — quanto resta aperta la riadozione di una macchina: la finestra entro cui la sonda
    # reinstallata prende il posto di quella precedente. Larga abbastanza per finire un'installazione
    # con calma (l'agent push-a ogni 60s, ma prima bisogna arrivarci), stretta abbastanza perché un
    # clic per sbaglio non lasci la macchina sostituibile per il resto della giornata. Scaduta la
    # finestra torna la regola normale: una credenziale viva non si tocca.
    REENROLLMENT_WINDOW_SECONDS = 1.hour.to_i
  end
end
