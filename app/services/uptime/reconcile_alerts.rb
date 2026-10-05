# frozen_string_literal: true

module Uptime
  # CYRA-792 — consegna gli avvisi uptime rimasti scritti e mai affidati alla coda.
  #
  # Il disservizio si registra PRIMA che l'avviso parta, e la transizione (aperto → chiuso) vive solo
  # nell'esecuzione che l'ha prodotta: se l'accodamento salta in quel varco, i controlli successivi
  # trovano un incident già aperto e non ripetono niente — l'avviso è perso per sempre. L'intento sta
  # quindi scritto sull'incident stesso (`down_alerted_at` / `up_alerted_at` nil = da consegnare) e
  # questo giro lo ripesca.
  #
  # Consegna UNA volta sola: il segno si scrive subito dopo l'accodamento, quindi il giro successivo
  # non ripassa la stessa riga; se l'accodamento fallisce di nuovo il segno non si scrive e la riga
  # resta in coda al prossimo giro. A valle, Alerting::Evaluate deduplica già per (regola, canale,
  # subject, finestra di throttle): un doppione nato da un secondo di sfortuna non diventa un secondo
  # avviso per chi lo riceve.
  #
  # Caduta e ripristino si consegnano ENTRAMBI, in quest'ordine: sono due cambi di stato, e chi legge
  # deve poter ricostruire cos'è successo, non ricevere solo la fine della storia. Ma la caduta non si
  # annuncia MAI dopo che il rientro è già stato annunciato: il controllo che rileva il ripristino
  # manda subito «è tornato attivo», e un «è giù» consegnato dopo racconterebbe una bugia su un sito
  # che in quel momento funziona. Quel disservizio resta scritto nella pagina dei disservizi, che è il
  # posto giusto per la storia passata.
  class ReconcileAlerts < ApplicationService
    # Sotto la grazia non si tocca niente: la consegna normale del controllo che ha appena registrato
    # il cambio di stato è ancora in corso, e ripescarla qui vorrebbe dire accodarla due volte.
    GRACE = 2.minutes
    # Oltre la finestra l'avviso non si consegna più: «il sito era giù ieri» non è un allarme, è
    # archeologia, e la pagina dei disservizi lo racconta già meglio. La riga resta com'è — mai
    # annunciata — perché è la verità.
    WINDOW = 1.day
    # Tetto per giro: un arretrato (motore dei lavori fermo a lungo) non deve trasformarsi in una
    # raffica di avvisi tutti insieme. Il giro dopo prende i restanti.
    BATCH = 200

    def initialize(at: Time.current)
      @at = at
    end

    def call
      recovered = pending_down.sum { |incident| deliver(incident, "uptime_down") }
      recovered += pending_up.sum { |incident| deliver(incident, "uptime_up") }
      Result.ok(recovered)
    end

    private

    # `includes(:monitor)`: progetto e ambiente dell'avviso stanno sul monitor, e senza precarico
    # sarebbe una query per riga del lotto.
    def pending_down
      Uptime::Incident.includes(:monitor)
                      .where(down_alerted_at: nil, up_alerted_at: nil, started_at: window)
                      .order(:started_at).limit(BATCH).to_a
    end

    # Solo incident chiusi: `resolved_at` dentro la finestra esclude da sé quelli ancora aperti, che
    # un ripristino da annunciare non ce l'hanno.
    def pending_up
      Uptime::Incident.includes(:monitor)
                      .where(up_alerted_at: nil, resolved_at: window)
                      .order(:resolved_at).limit(BATCH).to_a
    end

    def window = (@at - WINDOW)..(@at - GRACE)

    # Accodamento e segno di consegna stanno in Uptime::Incidents::Announce, lo stesso punto che usa
    # il controllo: lì vive il lock che impedisce a due esecutori di annunciare la stessa riga.
    def deliver(incident, event_type)
      Uptime::Incidents::Announce.call(incident: incident, event_type: event_type, at: @at).value ? 1 : 0
    rescue StandardError => e
      # La coda può essere ancora guasta: la riga resta pendente e il giro dopo riprova. Una riga che
      # esplode non si porta dietro le altre del lotto.
      Rails.logger.error("Uptime::ReconcileAlerts: #{incident.id} #{event_type} #{e.class}: #{e.message}")
      0
    end
  end
end
