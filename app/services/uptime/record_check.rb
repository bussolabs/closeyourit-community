# frozen_string_literal: true

module Uptime
  # Persiste l'esito di un ping: crea il Check, aggiorna salute+last_checked del monitor, e apre/chiude
  # l'incident al CAMBIO di stato (down CONFERMATO→apre, up→chiude). Tutto in transazione. Result pattern.
  #
  # Gli avvisi partono dopo il commit, e l'accodamento può fallire: l'INTENTO di avviso resta quindi
  # scritto sull'incident (`down_alerted_at` / `up_alerted_at` nil = da consegnare) e il segno si scrive
  # solo dopo l'accodamento riuscito. Chi ripesca il pendente: questo stesso service al controllo dopo,
  # per una caduta ancora in corso, e Uptime::ReconcileAlerts per tutto il resto (CYRA-792).
  class RecordCheck < ApplicationService
    def initialize(monitor:, result:)
      @monitor = monitor
      @result = result
    end

    def call
      now = Time.current
      check = nil
      ApplicationRecord.transaction do
        # Lock sul monitor PRIMA del check-then-act su open_incident: serializza i check concorrenti
        # sullo stesso monitor, così due esecuzioni non aprono due incident in parallelo (CYRA-269).
        # limits_concurrency sul CheckJob previene già i job paralleli — RecordCheck è l'unico punto che
        # apre incident, e gira solo da lì; questo è la difesa in profondità per trigger fuori dal job.
        # (Niente unique index DB: il grouping mantiene legittimamente più incident aperti raggruppati.)
        @monitor.lock!
        check = @monitor.checks.create!(
          up: @result.up, status_code: @result.status_code, response_time_ms: @result.response_time_ms,
          error: @result.error, checked_at: now
        )
        failures = @result.up ? 0 : @monitor.consecutive_failures + 1
        apply_incident_transition!(now, failures)
        attrs = { last_checked_at: now, current_status: status_after,
                  consecutive_failures: failures }
        attrs[:ssl_expires_at] = @result.ssl_expires_at if @result.ssl_expires_at
        @monitor.update!(attrs)
      end
      notify_alerts        # dopo il commit
      notify_ssl_expiry(now)      # dopo il commit
      notify_latency(now)         # dopo il commit
      broadcast_realtime(check)   # dopo il commit
      Result.ok(check)
    end

    private

    # Broadcast Turbo (sempre dopo il commit): aggiorna la riga monitor sulla lista uptime, prepende
    # il nuovo check alla show (stream del monitor) e — solo al cambio di stato — sostituisce la lista
    # incident. Isolamento tenant garantito da Realtime::Streams.
    #
    # Le pill di stato NON si spediscono più renderizzate: erano conteggi org-wide su target fisso
    # (`monitors_stats`, presente in ogni pagina uptime), quindi un membro che vede due progetti
    # leggeva i totali dell'intera organizzazione (CYRA-257). Ora si manda solo un page-refresh
    # throttlato: ogni viewer ri-fetcha la lista con la propria sessione e vede i PROPRI conteggi.
    # Il replace della riga (HTML) va sullo stream PER-PROGETTO: sul target per-record è un no-op nel
    # DOM per chi quel monitor non ce l'ha in pagina, ma l'HTML (nome/URL/stato) arriverebbe comunque
    # sul wire a chi il progetto non lo vede (CYRA-271). Tiene la riga immediata senza il throttle.
    def broadcast_realtime(check)
      org = @monitor.project.organization
      monitor_target = ActionView::RecordIdentifier.dom_id(@monitor)

      Turbo::StreamsChannel.broadcast_replace_to(
        Realtime::Streams.project_uptime(@monitor.project), target: monitor_target,
        partial: "member/monitoring/monitors/monitor_row", locals: { monitor: @monitor }
      )
      Realtime::ThrottledRefresh.call(Realtime::Streams.uptime(org))
      Turbo::StreamsChannel.broadcast_prepend_to(
        Realtime::Streams.monitor(@monitor), target: "monitor_checks_#{@monitor.id}",
        partial: "member/monitoring/monitors/check", locals: { check: check }
      )
      broadcast_incidents if @transition
    end

    # Lista incident (replace) — solo al cambio stato (apertura down / chiusura recovery): la lista cambia.
    # Broadcast condiviso con i service umani (grouping/update): fonte unica in Uptime::Incidents::Broadcast.
    def broadcast_incidents
      Uptime::Incidents::Broadcast.incidents(@monitor)
    end

    # Recovery (up) → chiude l'incident aperto, se presente. Down → apre un incident solo quando la
    # caduta è CONFERMATA: `failure_threshold` controlli falliti di fila (CYRA-776). Espone
    # @transition (:up/:down) e @incident per il trigger di alerting (solo al cambio stato), e
    # @down_confirmed per lo stato da persistere.
    def apply_incident_transition!(now, failures)
      if @result.up
        # Chiude TUTTI gli incident aperti del monitor, non solo il primo: eventuali doppioni rimasti da
        # prima del lock (CYRA-269) si auto-riparano al primo recovery invece di restare orfani per
        # sempre (la status page tornava a mostrare un disservizio inesistente). Nessun callback su
        # Uptime::Incident, né da update_all né da update!: il broadcast è esplicito qui sotto.
        open_incidents = @monitor.incidents.open.order(:started_at).to_a
        return if open_incidents.empty?

        @incident = open_incidents.first # il più vecchio = subject dell'alert di recovery
        # I doppioni si chiudono GIÀ annunciati: il ripristino si avvisa una volta, e il recupero
        # (CYRA-792) non deve ripescarne uno per finestra residua. Il subject invece si chiude con
        # `up_alerted_at` ancora nil — è l'intento di avviso, e resta scritto finché non parte.
        @monitor.incidents.open.where.not(id: @incident.id)
                .update_all(resolved_at: now, up_alerted_at: now, updated_at: now)
        @incident.update!(resolved_at: now)
        @transition = :up
      elsif (open = @monitor.open_incident)
        # Guasto già dichiarato: il contatore continua a salire, ma non si riapre né si ri-avvisa.
        @down_confirmed = true
        # A meno che l'avviso di quella caduta non sia mai arrivato alla coda: allora questo controllo
        # è anche il recupero (CYRA-792), e l'avviso parte entro il minuto invece di aspettare il giro
        # di Uptime::ReconcileAlertsJob.
        @unannounced_incident = open if open.down_alerted_at.nil?
      elsif failures >= @monitor.failure_threshold
        # `started_at: now` = l'istante in cui il guasto è stato CONFERMATO, non quello del primo
        # controllo andato storto: la durata dell'incident (e il downtime denormalizzato dai rollup)
        # racconta il disservizio dichiarato. I ping falliti restano tutti scritti, quindi la % di
        # disponibilità continua a contarli.
        @incident = @monitor.incidents.create!(started_at: now)
        @transition = :down
        @down_confirmed = true
      end
    end

    # Stato PERSISTITO dopo il check. Un fallito non confermato NON porta il monitor a `down`: la
    # pagina di stato pubblica e la pill leggono di qui, e dichiarare un disservizio che dopo
    # sessanta secondi non c'è più è lo stesso rumore delle notifiche, in forma visiva. Finché la
    # conferma manca lo stato resta quello di prima (up, oppure unknown per un monitor mai visto).
    def status_after
      return :up if @result.up
      return :down if @down_confirmed

      @monitor.current_status.to_sym
    end

    # Scadenza certificato: se il check è attivo (warn_days) e il not_after osservato rientra nella
    # finestra, avvisa via Alerting — al massimo una volta al giorno per monitor (ssl_alerted_on).
    def notify_ssl_expiry(now)
      warn_days = @monitor.ssl_expiry_warn_days
      expires_at = @result.ssl_expires_at
      return if warn_days.nil? || expires_at.nil?
      return if expires_at > now + warn_days.days
      return if @monitor.ssl_alerted_on == now.to_date

      Alerting::EvaluateJob.perform_later(
        event_type: "uptime_ssl_expiring", subject_type: "Uptime::Monitor", subject_id: @monitor.id,
        project_id: @monitor.project_id, environment_id: @monitor.environment_id
      )
      # La soppressione si scrive DOPO l'accodamento (CYRA-792): scritta prima, un accodamento fallito
      # zittiva il promemoria per tutto il resto della giornata. Così il controllo dopo riprova, e se
      # invece l'accodamento era passato ci pensa il throttle dell'alerting a non farne due avvisi.
      @monitor.update!(ssl_alerted_on: now.to_date)
    end

    # Latenza (CYRA-151): il sito risponde ma è lento oltre la soglia configurata → avvisa via Alerting,
    # al massimo una volta al giorno per monitor (latency_alerted_on), come lo SSL. Solo su check UP: un
    # down ha già il suo avviso (uptime_down). subject = il monitor, come uptime_ssl_expiring.
    def notify_latency(now)
      threshold = @monitor.latency_threshold_ms
      return unless @result.up
      return if threshold.nil? || @result.response_time_ms.nil?
      return if @result.response_time_ms <= threshold
      return if @monitor.latency_alerted_on == now.to_date

      Alerting::EvaluateJob.perform_later(
        event_type: "uptime_slow", subject_type: "Uptime::Monitor", subject_id: @monitor.id,
        project_id: @monitor.project_id, environment_id: @monitor.environment_id
      )
      # Come lo SSL qui sopra: la soppressione giornaliera segue l'accodamento, non lo precede.
      @monitor.update!(latency_alerted_on: now.to_date)
    end

    # Avvisa al cambio di stato (apertura/chiusura incident). A stato invariato l'unico avviso che può
    # partire è il RECUPERO di una caduta annunciata male (CYRA-792): l'incident è già aperto, quindi
    # nessuna transizione lo riproporrebbe mai più.
    def notify_alerts
      case @transition
      when :down then announce(@incident, "uptime_down")
      when :up   then announce(@incident, "uptime_up")
      else            announce(@unannounced_incident, "uptime_down")
      end
    end

    # Accodamento e segno di consegna vivono in un punto solo (Uptime::Incidents::Announce), condiviso
    # col giro di recupero: il segno si scrive dopo l'accodamento, e chi arriva secondo non ri-avvisa.
    def announce(incident, event_type)
      return if incident.nil?

      Uptime::Incidents::Announce.call(incident: incident, event_type: event_type)
    end
  end
end
