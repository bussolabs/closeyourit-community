# frozen_string_literal: true

module Metrics
  module Ingest
    # Normalizza un campione di metrica raw nel sottoinsieme indicizzato. `signature` è la chiave di
    # grouping (SQL templatizzato per slow_query, label per slow_method). NON tocca il DB.
    class Normalize < ApplicationService
      include ::Ingest::PayloadCleaning
      # Date del campione con la regola di Logs/Analytics (CYRA-1216): epoch in millisecondi riconosciuto
      # e riportato in secondi, istante oltre un'ora nel futuro → adesso.
      include ::Ingest::EpochTime
      # SQL templates and grouping share the queue boundary's scrubbing rules.
      include Scrubbing

      Normalized = Data.define(
        :kind, :sample_id, :duration_ms, :occurred_at, :environment, :title, :signature, :payload,
        :trace_id, :subtype, :sdk_name, :sdk_version
      )

      KINDS = %w[slow_query slow_method performance_issue].freeze
      TITLE_MAX = 255

      def initialize(payload:)
        # Guard non-Hash (un elemento non-oggetto nel batch → {} gestito come kind-nil, niente crash) +
        # strip null-byte (Postgres li rifiuta in text/jsonb: un \0 in sql/label farebbe fallire l'INSERT
        # nel job → retry x3 → drop silenzioso del campione).
        @payload = Scrub.call(payload: payload)
      end

      def call
        Normalized.new(
          kind: kind,
          sample_id: @payload["sample_id"].to_s.presence || SecureRandom.uuid,
          duration_ms: duration_ms, # nil = durata non valida: Record scarta il campione (R422-METRIC-007)
          occurred_at: parse_time(@payload["occurred_at"]),
          environment: @payload["environment"].presence,
          title: (job_context&.fetch("name") || core_signature).presence&.truncate(TITLE_MAX) || "metric",
          signature: signature,
          payload: scrubbed_payload,
          trace_id: @payload["trace_id"].presence,
          subtype: @payload["subtype"].presence,
          sdk_name: sdk_name,
          sdk_version: sdk_version
        )
      end

      private

      # Identità del client dal filo (Sentry `sdk: {name, version}`) — alimenta la card Monitoring tools.
      def sdk_name
        sdk = @payload["sdk"]
        sdk["name"].to_s.presence if sdk.is_a?(Hash)
      end

      def sdk_version
        sdk = @payload["sdk"]
        sdk["version"].to_s.presence if sdk.is_a?(Hash)
      end

      def kind
        value = @payload["kind"].to_s
        KINDS.include?(value) ? value : nil
      end

      # Signature = kind + parte umana (per non confondere una query e un metodo con lo stesso testo).
      def signature
        if job_context
          return JSON.generate([ "jobs/v1", kind, @payload["subtype"], *job_context.values_at("framework", "name", "queue", "measurement") ])
        end
        "#{@payload["kind"]}\n#{core_signature}"
      end

      def job_context
        return @job_context if defined?(@job_context)

        contexts = @payload["contexts"]
        candidate = contexts["job"] if contexts.is_a?(Hash)
        eligible = kind == "slow_method" || (kind == "performance_issue" && %w[slow_job job_queue_latency].include?(@payload["subtype"]))
        @job_context = if eligible && JobContext.valid?(candidate) && candidate.key?("measurement")
          candidate.transform_values { |value| value.is_a?(String) ? scrub_message(value) : value }
        end
      end

      def core_signature
        @core_signature ||= case @payload["kind"].to_s
        when "slow_query"  then templatize(@payload["sql"])
        when "slow_method" then @payload["label"].to_s
        when "performance_issue" then performance_signature
        else (@payload["sql"] || @payload["label"]).to_s
        end
      end

      # Signature canonica per i verdetti: subtype + chiave distintiva (+ call-site per i subtype
      # query-bound). Re-templatizza difensivamente lo SQL già offuscato dal client (idempotente):
      # il grouping è server-authoritative, non ci si fida dell'hash del client.
      def performance_signature
        parts = [ @payload["subtype"].to_s ]
        case @payload["subtype"].to_s
        when "slow_request", "high_query_count", "jank"
          # Per-route/schermo. slow_request/high_query_count (server) e jank (mobile) mandano `route`.
          parts << @payload["route"].to_s
        when "slow_external_http", "repeated_http"
          parts << @payload["http_host"].to_s
          parts << templatize(@payload["http_url"] || @payload["http_path"])
        when "rebuild_storm"
          # Per-widget: `source` = identificatore del widget ricostruito troppe volte.
          parts << @payload["source"].to_s
        else # n_plus_one, default → query-bound (template SQL + call-site)
          parts << templatize(@payload["sql"])
          parts << @payload["source"].to_s if @payload["source"].present?
        end
        parts.reject(&:blank?).join(" ")
      end

      # Durata in ms come numero finito, o nil se non valida (CYRA-1216). Assente → 0 e negativa → 0
      # come prima (un negativo avvelena min/avg). Una stringa numerica ("12.5") resta accettata, ma con
      # la conversione stretta: "abc" non diventa più 0. Infinito/NaN, booleani, liste e oggetti → nil:
      # prima Infinity finiva per sempre in total/max del gruppo e un tipo sbagliato faceva fallire il job
      # (e con lui l'intero lotto). Nessun tetto ai valori finiti.
      def duration_ms
        value = @payload["duration_ms"]
        number = case value
        when nil then 0.0
        when Numeric then value.to_f
        when String then (Float(value) rescue nil)
        end
        [ number, 0.0 ].max if number&.finite?
      end

      # Preserve the validated job context in the already scrubbed diagnostic payload.
      def scrubbed_payload
        cleaned = @payload.deep_dup
        cleaned["contexts"]["job"] = job_context if job_context
        cleaned
      end
    end
  end
end
