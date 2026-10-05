# frozen_string_literal: true

module Metrics
  module Ingest
    # Normalizza un campione di metrica raw nel sottoinsieme indicizzato. `signature` è la chiave di
    # grouping (SQL templatizzato per slow_query, label per slow_method). NON tocca il DB.
    class Normalize < ApplicationService
      include ::Ingest::PayloadCleaning
      # La ricorsione dello scrub e la redazione dei valori arrivano dal modulo condiviso (CYRA-735);
      # questo canale ne sovrascrive i DUE criteri, per il motivo scritto sotto le costanti.
      include ::Ingest::PiiScrubbing

      Normalized = Data.define(
        :kind, :sample_id, :duration_ms, :occurred_at, :environment, :title, :signature, :payload,
        :trace_id, :subtype, :sdk_name, :sdk_version
      )

      KINDS = %w[slow_query slow_method performance_issue].freeze
      UUID_RE = /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/i
      TITLE_MAX = 255

      # Denylist canonica (Errors::Ingest::Normalize / SDK — vedi
      # closeyourit-docs/decisions/2026-07-09-pii-scrub-parity.md) applicata come SEGMENTO INTERO della
      # chiave, non come sottostringa: qui lo scrub gira su TUTTO il payload metriche (non solo su
      # sezioni "libere" come in Errors) → una regex non ancorata redarebbe campi tecnici (`span_id`
      # contiene `pan`, `mapping` contiene `pin`) rompendo la correlazione. Il segmento normalizza
      # camelCase→snake così `authToken`/`userEmail` restano coperti. Vedi #sensitive_key?.
      SENSITIVE_SEGMENT = /\A(?:password|passwd|pwd|secret|token|bearer|authorization|cookie|csrf|session|pin|cvv|pan|ssn|iban|email|mail|phone|telephone|mobile|dob|birth|passport|credit|card)\z/

      # Composti senza separatore che i segmenti non catturano (`api_key`/`apiKey`/`x-api-key` → "apikey").
      # NB: `key` da solo NON è sensibile (cache_key/sort_key/primary_key non vanno redatti).
      SENSITIVE_COMPOUND = /apikey/

      # Chiavi il cui valore è un URL: strippane la query (può contenere token/email). Include i campi
      # http del payload metriche (http_url/http_path) oltre ai generici, quindi #url_key? sovrascrive
      # quello condiviso: una costante ridefinita nella classe NON cambia il metodo del modulo, che la
      # risolve dove è scritto.
      URL_KEY = /\A(url|uri|href|http_url|http_path|location|referer|referrer)\z/i

      # Chiavi il cui valore è testo SQL: nel payload conservato la query è templatizzata come la
      # signature (via #templatize) — così spariscono anche i numeri sensibili e i dollar-quote PG,
      # non solo i literal tra apici.
      SQL_KEY = /\Asql\z/i

      def initialize(payload:)
        # Guard non-Hash (un elemento non-oggetto nel batch → {} gestito come kind-nil, niente crash) +
        # strip null-byte (Postgres li rifiuta in text/jsonb: un \0 in sql/label farebbe fallire l'INSERT
        # nel job → retry x3 → drop silenzioso del campione).
        @payload = deep_clean(payload.is_a?(Hash) ? payload : {})
      end

      def call
        Normalized.new(
          kind: kind,
          sample_id: @payload["sample_id"].to_s.presence || SecureRandom.uuid,
          duration_ms: [ @payload["duration_ms"].to_f, 0.0 ].max, # clamp: un duration negativo avvelena min/avg
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

      # Nessuna euristica secondi/millisecondi qui (a differenza di Logs/Analytics/Errors): il
      # contratto SDK delle metriche dichiara i secondi. Del modulo condiviso serve la difesa dal
      # numero impossibile — un epoch fuori dal calendario faceva morire il job e perdere il campione.
      def parse_time(timestamp)
        case timestamp
        when Numeric then ::Ingest::Normalization.epoch_to_time(timestamp)
        when String  then (Time.zone.parse(timestamp) rescue nil)
        end || Time.current
      end

      # Numeri/uuid/hex/literal → placeholder: stesso SQL con literal diversi = stessa signature.
      # Usato anche per scrubbare il payload conservato (CYRA-40): rimuove ogni valore letterale
      # (stringhe tra apici E dollar-quote PostgreSQL $$…$$/$tag$…$tag$ E numeri) → nessuna PII
      # (email/token/ssn) sopravvive, che sia stringa o numero nudo. Il dollar-quote va prima dei
      # numeri: il tag può contenere cifre e verrebbe spezzato.
      def templatize(text)
        text.to_s
            .gsub(/\$([a-z0-9_]*)\$.*?\$\1\$/mi, "<str>") # dollar-quoted PostgreSQL ($$…$$, $tag$…$tag$)
            .gsub(/'(?:[^']|'')*'/, "<str>") # literal stringa (PII: email/token nei WHERE)
            .gsub(UUID_RE, "<uuid>")
            .gsub(/\b0x[0-9a-f]+\b/i, "<hex>")
            .gsub(/\d+/, "<n>")
      end

      # Payload conservato scrubbato server-side (parità con Errors::Ingest::Normalize): redige i valori
      # delle chiavi sensibili (ricorsivo su Hash E Array), strippa la query dagli URL (http_url) e i
      # literal stringa dallo SQL. Restituisce una struttura nuova — @payload resta raw per gli altri
      # campi derivati (signature/title lo templatizzano già).
      def scrubbed_payload
        cleaned = scrub_value(@payload)
        cleaned["contexts"]["job"] = job_context if job_context
        cleaned
      end

      # Ramo in più rispetto al modulo condiviso: il testo SQL non si redige, si templatizza (spariscono
      # i valori letterali, resta la forma della query che fa da chiave di raggruppamento).
      def scrub_entry(key, value)
        return templatize(value) if SQL_KEY.match?(key.to_s) && value.is_a?(String)

        super
      end

      # Chiave sensibile = un SEGMENTO intero (camelCase→snake, split su non-alfanumerici) matcha la
      # denylist, oppure la chiave compattata contiene un composto (apikey). Segmento intero, non
      # sottostringa: `span_id`/`mapping`/`cache_key` non sono falsi positivi.
      def sensitive_key?(key)
        normalized = key.to_s.gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
        normalized.split(/[^a-z\d]+/).any? { |segment| SENSITIVE_SEGMENT.match?(segment) } ||
          SENSITIVE_COMPOUND.match?(normalized.gsub(/[^a-z\d]/, ""))
      end

      def url_key?(key) = URL_KEY.match?(key.to_s)
    end
  end
end
