# frozen_string_literal: true

module Metrics
  module Ingest
    # Persiste un campione: calcola il fingerprint, upsert del gruppo, crea il sample e aggiorna gli
    # aggregati di durata ATOMICAMENTE (count, total, min/max, last_seen). Idempotente su sample_id.
    #
    # `call` processa UN campione (drop-in Sentry / replay). `call_batch` processa un ARRAY in un solo
    # job (CYRA-43): raggruppa per fingerprint e applica un SOLO UPDATE aggregato per gruppo — così un
    # POST batch di N campioni non produce N transazioni/broadcast (parità con Logs::Ingest::Record).
    #
    # La SEQUENZA (già registrato? → gruppo → tetto → riga → aggregati → fonte) vive in
    # ::Ingest::GroupedRecord, condivisa col canale degli errori (CYRA-736). Qui resta ciò che è delle
    # performance: la validazione di kind/subtype, gli aggregati di durata, l'alert alla soglia e il
    # percorso a lotti, che scrive N campioni con un solo `insert_all`.
    class Record < ::Ingest::GroupedRecord
      records_grouped_by groups: :metric_groups, occurrences: :metric_samples,
                         key: :sample_id, counter: :samples_count

      # Esito del batch: accepted = sample realmente inseriti, rejected = codici errore dei campioni
      # scartati (kind/subtype invalidi), per il logging aggregato del job.
      Summary = Data.define(:accepted, :rejected)

      def call
        normalized = Normalize.call(payload: @payload)
        return invalid_kind if normalized.kind.nil?
        return missing_subtype if normalized.kind == "performance_issue" && normalized.subtype.blank?

        sample_id = normalized.sample_id
        fingerprint = Fingerprint.call(signature: normalized.signature)

        existing = already_recorded(sample_id)
        return Result.ok(existing) if existing   # idempotenza: campione già registrato

        stored = nil
        ApplicationRecord.transaction do
          stored = store_occurrence(fingerprint: fingerprint, occurrence_id: sample_id, normalized: normalized)
        end
        track_source(normalized)                    # dopo il commit (fuori dalla transazione del gruppo)
        notify_alerts(stored.group, normalized)     # dopo il commit
        Metrics::Broadcast.refresh(stored.group)    # dopo il commit (page-refresh throttlato)
        Result.ok(stored.occurrence)
      rescue ActiveRecord::RecordNotUnique
        # Race su sample_id (due delivery concorrenti) → idempotente.
        Result.ok(already_recorded(sample_id))
      end

      # Entry-point batch (CYRA-43): un solo job per l'intero array del POST. Ritorna Result.ok(Summary).
      def self.call_batch(project:, payloads:)
        new(project: project).call_batch(payloads)
      end

      # Normalizza tutti i campioni, scarta gli invalidi (kind/subtype), raggruppa i validi per
      # fingerprint e persiste ogni gruppo con UN solo UPDATE aggregato. track_source/alert/broadcast
      # avvengono UNA volta per batch/gruppo, FUORI dalle transazioni (come nel path per-campione).
      def call_batch(payloads)
        classified = Array.wrap(payloads).map { |payload| classify(Normalize.call(payload: payload)) }
        rejected = classified.filter_map { |_normalized, code| code }
        # dedup interno al batch: un sample_id ripetuto nello stesso POST (replay) conta una volta —
        # tenere il primo evita il conflitto interno di insert_all e il doppio conteggio negli aggregati.
        valid = classified.filter_map { |normalized, code| normalized if code.nil? }.uniq(&:sample_id)

        touched = persist_groups(valid)

        track_source_batch(valid)               # una sola registrazione fonte per batch (fuori transazione)
        touched.each do |group, inserted|
          notify_alerts_batch(group, inserted)  # dopo il commit
          Metrics::Broadcast.refresh(group)      # dopo il commit (page-refresh throttlato)
        end

        Result.ok(Summary.new(accepted: touched.sum { |_group, inserted| inserted.size }, rejected: rejected))
      end

      private

      # [normalized, nil] se valido; [nil, codice] se da scartare (stessi codici del path per-campione).
      def classify(normalized)
        return [ nil, "R422-METRIC-002" ] if normalized.kind.nil?
        return [ nil, "R422-METRIC-003" ] if normalized.kind == "performance_issue" && normalized.subtype.blank?

        [ normalized, nil ]
      end

      # Un gruppo per fingerprint: upsert + insert dei sample nuovi + UN update aggregato, in una sola
      # transazione per gruppo (non per campione). Ritorna [[group, inserted_normalized], ...] per i soli
      # gruppi che hanno acquisito almeno un sample nuovo.
      #
      # Se OGNI sample del fingerprint è un duplicato (replay/race — insert_all li scarta), si fa
      # rollback: un fingerprint nuovo il cui unico campione ha un sample_id già registrato altrove
      # lascerebbe altrimenti un gruppo orfano VUOTO (upsert_group precede lo scarto dell'insert_all).
      # Il rollback annulla il gruppo appena creato; un gruppo pre-esistente resta intatto e non bumpato.
      def persist_groups(valid)
        valid.group_by { |normalized| Fingerprint.call(signature: normalized.signature) }.filter_map do |fingerprint, items|
          items = items.sort_by(&:occurred_at)   # first_seen del gruppo nuovo = occorrenza più vecchia
          group = nil
          inserted = []
          ApplicationRecord.transaction do
            group = upsert_group(fingerprint, items.first)
            inserted = insert_samples(group, items)
            raise ActiveRecord::Rollback if inserted.empty?

            bump_group_batch!(group, inserted)
          end
          [ group, inserted ] unless inserted.empty?
        end
      end

      # insert_all idempotente (ON CONFLICT DO NOTHING): il RETURNING dà i SOLI sample realmente
      # inseriti → il bump conta esattamente i nuovi, senza doppiare i replay. Il conflitto non ha
      # bersaglio (CYRA-750): la tabella è divisa a fette e su una tabella divisa PostgreSQL accetta
      # un indice unico solo se contiene la colonna del tempo, che renderebbe diversa ogni
      # riconsegna. L'unicità di [progetto, campione] vive quindi sulla SINGOLA fetta
      # (Ops::Partitions); resta scoperta solo una riconsegna a cavallo del cambio di mese.
      # `drop_body` è deciso RIGA PER RIGA con la STESSA regola del tetto del path a campione singolo
      # (::Ingest::GroupedRecord#over_cap_at?), applicata però al posto che la riga occuperà e non al
      # contatore del gruppo: `METRICS_MAX_BATCH` è 1.000, quindi un lotto a cavallo della soglia
      # conserverebbe altrimenti fino a 999 payload oltre il tetto. `base + index` è una stima per
      # eccesso (gli scarti per duplicato non consumano posti), e va bene così: sbaglia dalla parte di
      # buttare il corpo, non di tenerlo.
      def insert_samples(group, items)
        now = Time.current
        base = group.samples_count.to_i
        rows = items.each_with_index.map do |normalized, index|
          batch_sample_attributes(group, normalized, now, drop_body: over_cap_at?(base + index))
        end
        result = Metrics::Sample::Bulk.insert_all(rows, returning: %w[sample_id])
        inserted_ids = result.rows.flatten.to_set
        items.select { |normalized| inserted_ids.include?(normalized.sample_id) }
      end

      def batch_sample_attributes(group, normalized, now, drop_body: false)
        {
          project_id: @project.id,
          group_id: group.id,
          sample_id: normalized.sample_id,
          kind: Metrics::Sample.kinds.fetch(normalized.kind),
          occurred_at: normalized.occurred_at,
          duration_ms: normalized.duration_ms,
          environment: normalized.environment,
          trace_id: normalized.trace_id,
          subtype: normalized.subtype,
          payload: drop_body ? {} : normalized.payload,
          created_at: now
        }
      end

      # UN solo UPDATE aggregato per gruppo: +k al conteggio, somma al totale, min/max via LEAST/GREATEST,
      # last_seen GREATEST, title del campione più recente. Equivalente al bump per-campione applicato N volte.
      def bump_group_batch!(group, inserted)
        durations = inserted.map(&:duration_ms)
        min = durations.min
        max = durations.max
        last = inserted.map(&:occurred_at).max
        title = inserted.max_by(&:occurred_at).title
        Metrics::Group.where(id: group.id).update_all([
          "samples_count = samples_count + ?, " \
          "duration_total_ms = duration_total_ms + ?, " \
          "duration_min_ms = LEAST(COALESCE(duration_min_ms, ?), ?), " \
          "duration_max_ms = GREATEST(COALESCE(duration_max_ms, ?), ?), " \
          "last_seen_at = GREATEST(COALESCE(last_seen_at, ?), ?), " \
          "title = ?, updated_at = ?",
          inserted.size, durations.sum,
          min, min,
          max, max,
          last, last,
          title, Time.current
        ])
      end

      # Un solo alert per gruppo all'attraversamento della soglia (non uno per batch): il campione
      # peggiore del batch (max durata) alimenta le regole con threshold_ms. slow_query/slow_method
      # non generano alert.
      def notify_alerts_batch(group, inserted)
        return unless group.kind == "performance_issue"

        worst = inserted.max_by(&:duration_ms)
        enqueue_threshold_alert(group, environment: worst.environment, duration_ms: worst.duration_ms)
      end

      def invalid_kind
        Result.err(AppError.new("Metrica con kind non valido", code: "R422-METRIC-002", status: :unprocessable_content))
      end

      def missing_subtype
        Result.err(AppError.new("performance_issue senza subtype", code: "R422-METRIC-003", status: :unprocessable_content))
      end

      # Solo per i verdetti performance_issue: avvisa via metric_threshold quando il gruppo attraversa
      # la soglia di occorrenze del progetto. slow_query/slow_method non generano alert.
      def notify_alerts(group, normalized)
        return unless normalized.kind == "performance_issue"

        enqueue_threshold_alert(group, environment: normalized.environment, duration_ms: normalized.duration_ms)
      end

      # Accoda metric_threshold all'ATTRAVERSAMENTO della soglia del gruppo, NON 1:1 col volume dei
      # campioni (CYRA-48): con soglia default 1 ogni verdetto performance_issue accodava un EvaluateJob,
      # saturando la coda :alerts e affamando gli alert reali di errori/uptime sulla stessa coda. Gate
      # soglia (muto sotto soglia) + guard idempotente Rails.cache.write(unless_exist:) per gruppo con
      # cooldown: solo la prima delivery che vede il gruppo oltre soglia accoda; le successive (burst o
      # batch/delivery concorrenti) entro il cooldown sono no-op atomici, senza doppioni né miss.
      # Pattern del ramo errori (Errors::Ingest::Record#detect_spike). Il flag è SCADENTE, non permanente:
      # se perform_later fallisce (es. coda irraggiungibile) il gruppo non resta silenziato per sempre —
      # alla scadenza il prossimo campione oltre soglia riprova. Il throttle/dedup fine dell'invio vive
      # comunque in Alerting::Evaluate (bucket throttle_seconds).
      def enqueue_threshold_alert(group, environment:, duration_ms:)
        return if group.reload.samples_count < @project.performance_alert_threshold
        return unless Rails.cache.write("metrics:threshold:#{group.id}", 1, unless_exist: true,
                                        expires_in: Metrics::Constants::THRESHOLD_ALERT_COOLDOWN)

        Alerting::EvaluateJob.perform_later(
          event_type: "metric_threshold", subject_type: "Metrics::Group", subject_id: group.id,
          project_id: @project.id, environment: environment, duration_ms: duration_ms
        )
      end

      def new_group(group, normalized)
        group.title = normalized.title
        group.kind = normalized.kind
        group.subtype = normalized.subtype
        group.first_seen_at = normalized.occurred_at
        group.last_seen_at = normalized.occurred_at
        group.samples_count = 0
        group.duration_total_ms = 0.0
      end

      # `drop_body` (oltre il tetto): il payload resta vuoto. Il resto — durata, quando, ambiente,
      # trace, sottotipo — c'è sempre, quindi aggregati, grafici e correlazione non cambiano.
      def occurrence_attributes(sample_id, normalized, drop_body: false)
        {
          sample_id: sample_id,
          kind: normalized.kind,
          occurred_at: normalized.occurred_at,
          duration_ms: normalized.duration_ms,
          environment: normalized.environment,
          trace_id: normalized.trace_id,
          subtype: normalized.subtype,
          payload: drop_body ? {} : normalized.payload
        }
      end

      # Un solo UPDATE atomico: contatori + aggregati durata (min LEAST, max GREATEST, total +=),
      # last_seen (GREATEST), title più recente. Le performance non leggono niente dal gruppo pre-bump:
      # tutto ciò che serve sta nel campione appena arrivato.
      def bump_group!(group, normalized, _reading)
        Metrics::Group.where(id: group.id).update_all([
          "samples_count = samples_count + 1, " \
          "duration_total_ms = duration_total_ms + ?, " \
          "duration_min_ms = LEAST(COALESCE(duration_min_ms, ?), ?), " \
          "duration_max_ms = GREATEST(COALESCE(duration_max_ms, ?), ?), " \
          "last_seen_at = GREATEST(COALESCE(last_seen_at, ?), ?), " \
          "title = ?, updated_at = ?",
          normalized.duration_ms,
          normalized.duration_ms, normalized.duration_ms,
          normalized.duration_ms, normalized.duration_ms,
          normalized.occurred_at, normalized.occurred_at,
          normalized.title, Time.current
        ])
      end
    end
  end
end
