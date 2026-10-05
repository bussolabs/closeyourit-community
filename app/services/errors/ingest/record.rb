# frozen_string_literal: true

module Errors
  module Ingest
    # Persiste un evento Sentry: calcola il fingerprint, fa upsert del gruppo, crea l'evento e
    # aggiorna i contatori ATOMICAMENTE (events/users, first/last_seen, title/level), riaprendo il
    # gruppo su regressione (resolved → unresolved). Idempotente su event_id (replay/at-least-once).
    #
    # La SEQUENZA (già registrato? → gruppo → tetto → riga → aggregati → fonte) vive in
    # ::Ingest::GroupedRecord, condivisa col canale delle performance (CYRA-736). Qui resta ciò che è
    # degli errori e che le performance non hanno: la riapertura su regressione, la rilevazione degli
    # spike, il diradamento del lavoro sotto raffica, l'embedding del gruppo.
    class Record < ::Ingest::GroupedRecord
      records_grouped_by groups: :error_groups, occurrences: :error_events,
                         key: :event_id, counter: :events_count

      # Ciò che si legge dal gruppo PRIMA che i contatori si muovano: dopo l'UPDATE atomico questi
      # fatti non sono più leggibili, e `new_user` addirittura cambia risposta appena la riga è scritta.
      Reading = Data.define(:created, :was_resolved, :was_unresolved, :title_changed, :burst_tick, :new_user)

      def initialize(project:, payload: nil, staged_user_hash: nil)
        super(project: project, payload: payload)
        # Only the worker supplies this column; client payload fields never override it.
        @staged_user_hash = staged_user_hash if staged_user_hash.is_a?(String) && staged_user_hash.match?(/\A[0-9a-f]{16}\z/)
      end

      def call
        normalized = Normalize.call(payload: @payload)
        normalized = normalized.with(user_hash: @staged_user_hash) if @staged_user_hash
        @payload = normalized.payload
        event_id = normalized.event_id.presence || SecureRandom.hex(16)
        fingerprint = Fingerprint.call(payload: @payload)
        # CYRA-153: le regole di raggruppamento del progetto possono rimappare il fingerprint prima
        # dell'upsert (nessuna regola → invariato). Va qui, non dentro Fingerprint: quello resta il
        # grouping automatico puro, questo è l'override che il team configura sopra.
        fingerprint = ApplyGroupingRules.call(project: @project, payload: @payload, fingerprint:)

        existing = already_recorded(event_id)
        if existing
          reconcile_artifacts(existing)
          return Result.ok(existing)
        end

        stored = nil
        reopened = false
        ApplicationRecord.transaction do
          ::Ingest::EventLock.acquire!(project_id: @project.id, event_id: event_id, domain: "errors")
          existing = already_recorded(event_id)
          next if existing

          stored = store_occurrence(fingerprint: fingerprint, occurrence_id: event_id, normalized: normalized)
          # Regressione VERA solo da resolved e con release pari/successiva al fix (CYRA-44): un
          # evento pre-fix (client vecchio) è un residuo, non riapre né allarma. reopen_as_regression!
          # transita atomicamente (gate WHERE status=resolved) e ritorna true SOLO al delivery che ha
          # DAVVERO riaperto → in concorrenza un solo alert error_regression, non uno per delivery.
          reopened =
            if stored.reading.was_resolved && !stale_reoccurrence?(stored.group, normalized)
              reopen_as_regression!(stored.group, normalized)
            else
              false
            end
        end
        reconcile_artifacts(existing || stored&.occurrence)
        return Result.ok(existing) if existing

        group = stored.group
        reading = stored.reading
        # After the commit: the release row takes every event of a version, so holding it together
        # with the group row doubled the contention (CYRA-894).
        Projects::Release.track_event!(project: @project, version: normalized.release,
                                       environment: normalized.environment,
                                       occurred_at: normalized.occurred_at)
        track_source(normalized)                                   # dopo il commit
        notify_alerts(group, reading.created, reopened, normalized) # dopo il commit
        # In raffica il lavoro che passa da Rails.cache — probe dello spike e segnale di refresh — si fa
        # una volta ogni TELEMETRY_BURST_WORK_EVERY. Fuori dalla raffica: sempre, come prima.
        if reading.burst_tick
          detect_spike(group, reading.created, reading.was_unresolved, normalized)  # spike su unresolved
          Errors::Broadcast.refresh(group)                                          # page-refresh throttlato
        end
        # Embedding SOLO su gruppo nuovo o title cambiato — MAI per-occorrenza (volume ingest).
        Errors::EmbedGroupJob.perform_later(group_id: group.id) if reading.created || reading.title_changed
        Result.ok(stored.occurrence)
      rescue ActiveRecord::RecordNotUnique
        # Race su event_id (due deliveries concorrenti) → idempotente.
        Result.ok(already_recorded(event_id))
      end

      private

      def reconcile_artifacts(event)
        ::Crashes::Reconcile.call(project: @project, event: event)
        enqueue_symbolication(event)
      end

      def enqueue_symbolication(event)
        return unless event && (%w[javascript node java native].include?(event.payload["platform"]) || @project.crash_reports.where(event_id: event.event_id).where.not(manifest: {}).exists?)
        Errors::SymbolicateJob.perform_later(project_id: @project.id, event_id: event.id, event_created_at: event.created_at.iso8601(6))
      end

      # CYRA-192: un fingerprint può essere stato ASSORBITO da una fusione. Senza questo secondo
      # tentativo la `find_or_create_by!` ne creerebbe uno nuovo e il gruppo appena fuso ricomparirebbe
      # nell'elenco alla prima occorrenza successiva. Query fatta solo quando il fingerprint diretto non
      # esiste (gruppi nuovi o fusi), quindi non pesa sul caso comune.
      def absorbed_group(fingerprint)
        groups.where("merged_fingerprints @> ARRAY[?]::text[]", [ fingerprint ]).first
      end

      def new_group(group, normalized)
        group.title = normalized.title
        group.culprit = normalized.culprit
        group.level = normalized.level
        group.release = normalized.release
        group.first_seen_release = normalized.release
        group.first_seen_at = normalized.occurred_at
        group.last_seen_at = normalized.occurred_at
        group.events_count = 0
        group.users_count = 0
      end

      # Le sei letture pre-bump. `new_user` DEVE stare qui e non dopo la create: l'evento appena
      # scritto porta lo stesso user_hash e farebbe rispondere «già visto» a ogni utente nuovo.
      def pre_bump_reading(group, normalized)
        created = group.previously_new_record?     # gruppo appena creato?
        Reading.new(
          created: created,
          was_resolved: group.status_resolved?,    # stato PRIMA del bump (bump usa update_all)
          was_unresolved: group.status_unresolved?, # idem: gate dello spike (ignored resta muto)
          # group è pre-bump: se il title dell'occorrenza differisce, bump_group! lo aggiornerà.
          title_changed: !created && group.title != normalized.title,
          burst_tick: burst_tick?(group, normalized),
          new_user: new_user_for?(group, normalized.user_hash)
        )
      end

      def new_user_for?(group, user_hash)
        user_hash.present? && !group.events.where(user_hash: user_hash).exists?
      end

      # Raffica IN CORSO: l'occorrenza precedente è arrivata pochi secondi fa. `last_seen_at` è
      # pre-bump e già in memoria — nessuna query. Un delta negativo (evento arretrato, clock del
      # client) non conta come raffica.
      def hot?(group, normalized)
        last = group.last_seen_at
        return false if last.nil? || normalized.occurred_at.nil?

        gap = normalized.occurred_at - last
        gap >= 0 && gap <= Monitoring::Constants::TELEMETRY_BURST_GAP
      end

      # Questa occorrenza fa il lavoro che passa da `Rails.cache`? Fuori dalla raffica sempre; in
      # raffica una ogni TELEMETRY_BURST_WORK_EVERY.
      #
      # I chiamanti sono due e insieme costavano da due a quattro scritture per occorrenza: la probe
      # dello spike (una) e `Errors::Broadcast.refresh`, che tocca DUE stream — lista e show — ognuno con
      # una scrittura per il lock leading e, se quello non passa, una per il lock trailing. Durante la
      # raffica del 2026-07-29 sono stati oltre un milione di tentativi di scrittura su un file SQLite
      # già in lock, ed è quel lock che generava l'errore in arrivo: il monitoraggio si mordeva la coda.
      #
      # Il gate è "grande E caldo", MAI il solo `events_count`, che è cumulativo: da solo spegnerebbe
      # refresh e rilevazione per sempre su un errore cronico che raccoglie cinquemila occorrenze in sei
      # mesi. Deterministico sul contatore pre-bump: nessuna query e nessuna cache per decidere se usare
      # la cache.
      def burst_tick?(group, normalized)
        return true unless over_cap?(group) && hot?(group, normalized)

        (group.events_count.to_i % Monitoring::Constants::TELEMETRY_BURST_WORK_EVERY).zero?
      end

      # `drop_body` (oltre il tetto): payload, stacktrace e contesto restano vuoti. Sono i tre jsonb che
      # pesano; tutto il resto — quando, dove, quale release, quale utente, quale trace — resta, quindi
      # la riga continua a servire correlazione, filtri e istogrammi. Le colonne sono NOT NULL con
      # default `{}`: si scrive il default, non NULL.
      def occurrence_attributes(event_id, normalized, drop_body: false)
        {
          event_id: event_id,
          occurred_at: normalized.occurred_at,
          level: normalized.level,
          environment: normalized.environment,
          release: normalized.release,
          server_name: normalized.server_name,
          runtime: normalized.runtime,
          os_name: normalized.os_name,
          os_version: normalized.os_version,
          app_version: normalized.app_version,
          user_hash: normalized.user_hash,
          trace_id: normalized.trace_id,
          span_id: normalized.span_id,
          replay_session_id: normalized.replay_session_id,
          handled: normalized.handled,
          payload: drop_body ? {} : normalized.payload,
          stacktrace: drop_body ? {} : normalized.stacktrace,
          context: drop_body ? {} : normalized.context
        }
      end

      # Un solo UPDATE atomico dei contatori e degli attributi dell'occorrenza più recente: events/
      # users, last_seen (GREATEST), title/level/release. has_unhandled è MONOTÒNO (OR): resta true una
      # volta che il gruppo ha visto un crash non gestito (handled=false); handled=true/nil non lo
      # spengono. Lo status NON si tocca qui — il reopen su regressione è un UPDATE condizionale separato
      # (reopen_as_regression!) per rilevare in modo atomico QUALE delivery ha davvero riaperto.
      def bump_group!(group, normalized, reading)
        # user_context_seen è MONOTÒNO come has_unhandled (OR): si accende al primo evento che porta
        # l'identità dell'utente e non si spegne più (CYRA-380), così «mai tracciato» resta un fatto
        # storico affidabile anche dopo split/potatura, che invece azzerano users_count.
        Errors::Group.where(id: group.id).update_all([
          "events_count = events_count + 1, " \
          "users_count = users_count + ?, " \
          "title = ?, level = ?, release = COALESCE(?, release), " \
          "has_unhandled = has_unhandled OR ?, " \
          "user_context_seen = user_context_seen OR ?, " \
          "last_seen_at = GREATEST(COALESCE(last_seen_at, ?), ?), updated_at = ?",
          (reading.new_user ? 1 : 0),
          normalized.title, Errors::Group.levels[normalized.level], normalized.release,
          normalized.handled == false,
          normalized.user_hash.present?,
          normalized.occurred_at, normalized.occurred_at,
          Time.current
        ])
      end

      # Riapre il gruppo su regressione confermata, ma SOLO se è ancora resolved: il gate atomico
      # WHERE status=resolved fa sì che, tra più delivery concorrenti che l'hanno visto resolved, un
      # solo UPDATE transiti (update_all ritorna 1) e gli altri ritornino 0 → un solo alert
      # error_regression (CYRA-44). Registra la release che ha causato il reopen.
      def reopen_as_regression!(group, normalized)
        Errors::Group
          .where(id: group.id, status: Errors::Group.statuses["resolved"])
          .update_all([ "status = ?, regressed_in_release = ?, updated_at = ?",
                        Errors::Group.statuses["unresolved"], normalized.release, Time.current ])
          .positive?
      end

      # Un'occorrenza su gruppo RESOLVED è "residua" (non regressione) quando la sua release è
      # SICURAMENTE precedente a quella in cui il gruppo fu risolto — un client vecchio che ripete un
      # errore già corretto a monte (CYRA-44). Senza resolved_in_release (nessun binding), senza
      # release sull'evento, o ordine indeterminato → conservativo: regressione (meglio un alert in
      # più che silenziare una vera regressione).
      def stale_reoccurrence?(group, normalized)
        reference = group.resolved_in_release
        return false if reference.blank?

        Projects::Release.at_or_after?(project: @project, version: normalized.release,
                                       reference: reference) == false
      end

      # Dopo il commit: avvisa SOLO su transizione significativa — gruppo nuovo (error_new) o
      # riaperto da resolved (error_regression). Occorrenza su gruppo già unresolved/ignored, o
      # residuo pre-fix (reopened=false), → muta.
      def notify_alerts(group, created, reopened, normalized)
        type =
          if created
            "error_new"
          elsif reopened
            "error_regression"
          end
        return if type.nil?

        Alerting::EvaluateJob.perform_later(
          event_type: type, subject_type: "Errors::Group", subject_id: group.id,
          project_id: @project.id, environment: normalized.environment,
          level: Errors::Group.levels[normalized.level], handled: normalized.handled
        )
      end

      # Spike/surge su gruppo GIÀ unresolved: un errore a basso volume che esplode (tipico post-deploy)
      # non è né nuovo né una regressione → notify_alerts lo ignora. Solo su unresolved: created →
      # error_new, resolved → error_regression, ignored → muto per scelta dell'operatore.
      #
      # Due throttle DISTINTI (cache atomica come deliver_channels; il job :ingest gira sul worker,
      # niente corse). PROBE (breve): limita la query buckets_for sotto burst — acquisito prima di
      # sapere se c'è uno spike, quindi un'occorrenza normale ceca la detection al massimo per
      # ERROR_SPIKE_PROBE_INTERVAL (non per il cooldown). COOLDOWN (lungo): scritto SOLO quando lo spike
      # è confermato — evita di riemettere ad ogni campione mentre l'esplosione persiste; un no-spike
      # NON lo consuma, così un burst iniziato subito dopo resta rilevabile.
      def detect_spike(group, created, was_unresolved, normalized)
        return if created || !was_unresolved

        # In raffica ci si arriva una volta ogni TELEMETRY_BURST_WORK_EVERY: il gate è nel chiamante
        # (`burst_tick?`), perché lo condivide col segnale di refresh realtime — sono lo stesso problema,
        # scritture su una cache SQLite a ogni occorrenza, e vanno diradate insieme (CYRA-196).
        probe = "errors:spike:probe:#{group.id}"
        return if Ops::LocalGate.held?(probe) # no locking write for a probe this process holds (CYRA-890)
        return unless Rails.cache.write(probe, 1, unless_exist: true,
                                        expires_in: Errors::Constants::SPIKE_PROBE_INTERVAL)

        Ops::LocalGate.hold(probe, expires_in: Errors::Constants::SPIKE_PROBE_INTERVAL)
        return unless spiking?(group)

        cooldown = "errors:spike:alert:#{group.id}"
        return unless Rails.cache.write(cooldown, 1, unless_exist: true,
                                        expires_in: Errors::Constants::SPIKE_ALERT_COOLDOWN)

        Alerting::EvaluateJob.perform_later(
          event_type: "error_spike", subject_type: "Errors::Group", subject_id: group.id,
          project_id: @project.id, environment: normalized.environment,
          level: Errors::Group.levels[normalized.level], handled: normalized.handled
        )
      end

      # Il bucket corrente (in corso, include l'occorrenza appena registrata) supera SIA la soglia
      # minima assoluta (anti-rumore su gruppi a bassissimo volume) SIA FACTOR× la media dei bucket
      # precedenti (spike relativo). Baseline vuota/zero (gruppo dormiente) → domina la sola soglia
      # assoluta. Quando lo spike diventa la nuova normalità (baseline inquinata dal burst) l'alert
      # rientra da sé: comportamento voluto, evita di ripetere all'infinito.
      def spiking?(group)
        counts = Errors::Group.buckets_for([ group.id ], Errors::Constants::SPIKE_RANGE)
                              .fetch(group.id).map { |bucket| bucket[:count] }
        current = counts.last.to_i
        return false if current < Errors::Constants::SPIKE_MIN_COUNT

        baseline = counts[0...-1]
        average = baseline.empty? ? 0.0 : baseline.sum.to_f / baseline.size
        current >= Errors::Constants::SPIKE_FACTOR * average
      end
    end
  end
end
