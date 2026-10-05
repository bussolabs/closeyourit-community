# frozen_string_literal: true

module Errors
  # Costanti del dominio error monitoring (rules/constants.md): quanto si conserva, quanto grande può
  # essere un evento in ingresso e quando una raffica di occorrenze diventa uno spike da segnalare.
  # Ciò che errori e metriche condividono (fedeltà della telemetria, densità delle pagine) sta in
  # Monitoring::Constants.
  module Constants
    # Retention di default (giorni) — gerarchia god → org → progetto come i log.
    RETENTION_DEFAULT_DAYS = 30

    # Tetto in BYTE del corpo dell'ingest bearer prima dell'enqueue, misurato su `request.content_length`
    # (CYRA-112). Distinto dai cap di BATCH: `Metrics::Constants::MAX_BATCH` limita il NUMERO di campioni
    # ma non la loro dimensione, e `/events` (evento singolo) non aveva alcun cap applicativo — solo quello
    # di Rack. Un payload sotto il conteggio massimo ma sproporzionatamente grande raggiungeva comunque
    # la coda (Solid Queue su Postgres) come argomento del job, gonfiandola. Il gate (su `content_length`,
    # nessun parse) sta in TESTA alla catena via `prepend_before_action`: l'autenticazione ingest, senza
    # bearer né X-Sentry-Auth, legge `params[:sentry_key]` e con ciò parserebbe il body — precederla evita
    # che un payload enorme (anche anonimo o malformato) venga parsato. Oltre → `R413-INGEST-002`.
    #
    # Valore allineato al limite DECOMPRESSO dell'ingest Sentry (`Errors::Ingest::EnvelopeParser`
    # `MAX_DECOMPRESSED`, 5 MB): `/events` bearer confluisce nella stessa pipeline, un evento non
    # compresso ha lo stesso peso ammesso di uno arrivato via DSN. È anche il valore da coordinare col
    # `DefaultMaxBodyBytes` del gateway ingest, che resta "almeno altrettanto restrittivo" di Rails
    # (API.md §1.4): Rails è il tetto, il gateway può solo stringere.
    EVENTS_MAX_BYTES = 5.megabytes

    # Rilevamento spike/surge degli errori (Errors::Ingest::Record). Un gruppo GIÀ unresolved a basso
    # volume che esplode (es. dopo un deploy) non è né nuovo né una regressione → sfuggirebbe agli
    # alert. La detection confronta il bucket corrente col rate di baseline (Errors::Group.buckets_for)
    # e allerta (event_type error_spike) se supera SIA una soglia minima assoluta (anti-rumore su
    # gruppi a bassissimo volume) SIA un fattore relativo rispetto alla media dei bucket precedenti.
    # SPIKE_RANGE deve essere una chiave di Errors::Group::RANGES; "30m" (bucket da 1 minuto) dà
    # reattività post-deploy e una baseline recente rappresentativa.
    SPIKE_RANGE = "30m"
    # Minimo di occorrenze nel bucket corrente perché conti come spike: sotto, è rumore da ignorare
    # (2 vs 0 = ∞× ma irrilevante). Calibrato sul bucket da 1 minuto della finestra "30m".
    SPIKE_MIN_COUNT = 20
    # Il bucket corrente deve superare FACTOR× la media dei bucket precedenti (baseline a zero → domina
    # la sola soglia minima assoluta). Un semplice raddoppio NON è uno spike; serve un salto netto.
    SPIKE_FACTOR = 5
    # Throttle della QUERY per gruppo: buckets_for è costosa e non va ripetuta ad ogni occorrenza sotto
    # burst. BREVE (≈ dimensione del bucket): è acquisito PRIMA di sapere se c'è uno spike, quindi
    # un'occorrenza normale ceca la detection al massimo per questo intervallo (non per il cooldown).
    SPIKE_PROBE_INTERVAL = 1.minute
    # Cooldown dell'ALERT per gruppo: scritto SOLO quando uno spike è confermato → un'occorrenza normale
    # non consuma questo budget. Evita di riemettere error_spike ad ogni campione mentre l'esplosione
    # persiste (Alerting::Evaluate deduplica poi la consegna col proprio throttle di regola).
    SPIKE_ALERT_COOLDOWN = 5.minutes
  end
end
