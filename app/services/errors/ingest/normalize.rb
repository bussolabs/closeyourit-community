# frozen_string_literal: true

module Errors
  module Ingest
    # Normalizza un evento Sentry raw nel sottoinsieme che CloseYourIt indicizza, applicando la
    # policy PII (email/ip/cookie/header auth rimossi). Restituisce un Normalized immutabile; il
    # payload conservato è scrubbato (lossless tranne i campi PII). NON tocca il DB.
    class Normalize < ApplicationService
      include ::Ingest::PayloadCleaning
      include ::Ingest::PiiScrubbing

      Normalized = Data.define(
        :event_id, :occurred_at, :level, :environment, :release, :server_name, :runtime,
        :os_name, :os_version, :app_version,
        :user_hash, :title, :culprit, :payload, :stacktrace, :context, :trace_id, :span_id,
        :replay_session_id, :sdk_name, :sdk_version, :handled
      )

      LEVELS = %w[debug info warning error fatal].freeze
      TITLE_MAX = 255

      # La denylist PII (chiavi, header, chiavi-indirizzo) vive in ::Ingest::PiiScrubbing, che questa
      # classe include: le costanti restano leggibili come Errors::Ingest::Normalize::SENSITIVE_KEY.

      # Sezioni di metadati liberi (oltre user/request/breadcrumbs) da ri-scrubbare difensivamente.
      CONTEXT_SECTIONS = %w[tags extra contexts].freeze

      # timestamp >= questa soglia = epoch in millisecondi (JS Date.now()), non secondi.
      MS_EPOCH_THRESHOLD = 1_000_000_000_000
      MAX_FUTURE_SKEW = 5.minutes

      def initialize(payload:)
        # Postgres rifiuta i null byte in text/jsonb: puliscili una volta su tutto il payload,
        # così ogni colonna/stringa derivata è sicura da persistere (evita il crash silenzioso
        # nel job con perdita dell'evento). Il costo è compensato: deep_clean produce già la copia
        # difensiva che altrimenti farebbe deep_dup.
        @payload = deep_clean(payload || {})
        # Canonicalize before scrubbing and durable staging; all downstream readers share this shape.
        @payload["exception"] = { "values" => @payload["exception"] } if @payload["exception"].is_a?(Array)
        @source_user_hash = user_hash
        @payload = Scrub.call(payload: @payload)
      end

      def call
        Normalized.new(
          event_id: @payload["event_id"].to_s.presence,
          occurred_at: parse_time(@payload["timestamp"]),
          level: level,
          environment: @payload["environment"].presence,
          release: @payload["release"].presence,
          server_name: @payload["server_name"].presence,
          runtime: runtime,
          os_name: os_context["name"].to_s.presence,
          os_version: os_context["version"].to_s.presence,
          app_version: app_version,
          user_hash: @source_user_hash,
          title: title,
          culprit: culprit,
          payload: scrubbed_payload,
          stacktrace: stacktrace,
          context: context,
          trace_id: trace_id,
          span_id: span_id,
          replay_session_id: replay_session_id,
          sdk_name: sdk_name,
          sdk_version: sdk_version,
          handled: self.class.handled_in(@payload)
        )
      end

      # mechanism.handled dell'ultima exception (contratto Sentry emesso dai 3 SDK): distingue una
      # cattura volontaria (true, capture_exception) da un crash non gestito (false). SOLO un vero
      # booleano è informativo — mechanism assente/non-Hash o handled non-booleano → nil (sconosciuto:
      # es. capture_message senza exception). Niente default a true: nil è informazione onesta.
      # Metodo di classe = UNICA fonte di verità, condivisa da #call (ingest) e da
      # Errors::BackfillHandledJob (recupero dal payload conservato, dove il mechanism è integro).
      def self.handled_in(payload)
        return nil unless payload.is_a?(Hash)

        values = EventPayload.exception_values(payload)
        last = values.is_a?(Array) ? values.last : nil
        return nil unless last.is_a?(Hash)

        mechanism = last["mechanism"]
        return nil unless mechanism.is_a?(Hash)

        value = mechanism["handled"]
        value if [ true, false ].include?(value)
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

      def level
        lvl = @payload["level"].to_s
        LEVELS.include?(lvl) ? lvl : "error"
      end

      # Accetta epoch in secondi o millisecondi (JS Date.now()) e clampa i timestamp nel futuro:
      # senza clamp un ms-epoch o un orologio client sballato avvelena last_seen_at (gruppo bloccato
      # in cima a `recent`, istogramma sballato). Regola condivisa, misure di questo canale (soglia e
      # tolleranza sono più strette di quelle di Logs/Analytics: vedi le costanti sopra).
      def parse_time(ts)
        time = case ts
        when Numeric then ::Ingest::Normalization.epoch_to_time(ts, ms_threshold: MS_EPOCH_THRESHOLD)
        when String  then (Time.zone.parse(ts) rescue nil)
        end || Time.current
        ::Ingest::Normalization.clamp_future(time, skew: MAX_FUTURE_SKEW)
      end

      def last_exception
        values = @payload.dig("exception", "values")
        values.is_a?(Array) ? values.last : nil
      end

      def title
        if (exc = last_exception)
          [ exc["type"], exc["value"] ].compact.join(": ").presence&.truncate(TITLE_MAX)
        else
          (message_text || @payload["transaction"] || "Error").to_s.truncate(TITLE_MAX)
        end
      end

      def culprit
        exc = last_exception
        frames = exc&.dig("stacktrace", "frames")
        return @payload["transaction"].presence unless frames.is_a?(Array) && frames.any?

        frame = frames.reverse.find { |f| f["in_app"] } || frames.last
        [ frame["module"] || frame["filename"], frame["function"] ].compact.join(" in ").presence
      end

      def message_text
        Errors::MessageText.read(@payload)
      end

      def runtime
        rt = contexts_hash["runtime"]
        return nil unless rt.is_a?(Hash)

        [ rt["name"], rt["version"] ].compact.join(" ").presence
      end

      # contexts.os degli SDK mobile/browser ({ name, version }) — colonne dedicate per breakdown/filtri.
      def os_context
        os = contexts_hash["os"]
        os.is_a?(Hash) ? os : {}
      end

      # contexts.app → "app_version+build" (stile pubspec). Accetta sia build_number (closeyourit-dart)
      # sia app_build (SDK Sentry ufficiali).
      def app_version
        app = contexts_hash["app"]
        return nil unless app.is_a?(Hash)

        version = app["app_version"].to_s.presence
        build = (app["build_number"] || app["app_build"]).to_s.presence
        [ version, build ].compact.join("+").presence
      end

      # Correlazione log↔errori: la gemma nativa mette trace_id top-level; gli SDK Sentry
      # ufficiali lo annidano in contexts.trace.trace_id (il top-level, quando c'è, vince).
      def trace_id
        @payload["trace_id"].presence || sentry_trace_id
      end

      def span_id
        trace = contexts_hash["trace"]
        return nil unless trace.is_a?(Hash)

        value = trace["span_id"]
        value.downcase if value.is_a?(String) && value.match?(/\A[0-9a-f]{16}\z/i) && value != "0" * 16
      end

      def sentry_trace_id
        trace = contexts_hash["trace"]
        return nil unless trace.is_a?(Hash)

        trace["trace_id"].to_s.presence
      end

      # Correlazione errore↔session replay: il browser SDK mette l'id della sessione
      # di replay in contexts.replay.replay_id (parità con la convenzione Sentry).
      def replay_session_id
        replay = contexts_hash["replay"]
        return nil unless replay.is_a?(Hash)

        replay["replay_id"].to_s.presence
      end

      # `contexts` arriva dal client: difendersi da forme non-Hash (un dig su String solleverebbe).
      def contexts_hash
        ctx = @payload["contexts"]
        ctx.is_a?(Hash) ? ctx : {}
      end

      # Hash PII-safe dell'utente (per stimare users_count senza conservare PII).
      def user_hash
        user = @payload["user"]
        return nil unless user.is_a?(Hash)

        id = user.values_at("id", "email", "ip_address").compact.first
        id.present? ? Digest::SHA256.hexdigest(id.to_s)[0, 16] : nil
      end

      # Colonna stacktrace dedicata: scruba i vars dei frame (password/api_key nelle variabili locali
      # degli SDK Sentry ufficiali) prima di persistere.
      def stacktrace
        st = last_exception&.dig("stacktrace")
        st.is_a?(Hash) ? scrub_stacktrace(st) : {}
      end

      # tags/extra/contexts ri-scrubbati (difesa in profondità): redige le chiavi sensibili
      # preservando la struttura (es. contexts.runtime resta, solo i valori sensibili → [FILTERED]).
      def context
        CONTEXT_SECTIONS.index_with { |key| @payload[key] }.compact
      end

      # Rimuove i campi PII dal payload conservato (resta lossless per tutto il resto). Il backend è
      # l'autorità PII: ri-scruba anche request.data, breadcrumb.data, vars dei frame e i metadati
      # liberi (difesa in profondità, anche quando il client li ha già scrubati a monte).
      def scrubbed_payload
        payload = @payload.deep_dup
        scrub_user(payload)
        scrub_request(payload)
        scrub_breadcrumbs(payload)
        scrub_frames_vars(payload)
        payload
      end

      def scrub_user(payload)
        return unless payload["user"].is_a?(Hash)

        payload["user"] = payload["user"].except("email", "ip_address", "username")
      end

      def scrub_request(payload)
        request = payload["request"]
        return unless request.is_a?(Hash)

        request.delete("cookies")
        request.delete("env")
        request["url"] = strip_query(request["url"]) if request["url"].is_a?(String)
        request["query_string"] = scrub_query_string(request["query_string"]) if request["query_string"].is_a?(String)
        request["headers"] = scrub_headers(request["headers"]) if request["headers"].is_a?(Hash)
        request["data"] = scrub_value(request["data"]) if request["data"].is_a?(Hash) || request["data"].is_a?(Array)
      end

      def scrub_breadcrumbs(payload)
        breadcrumbs = payload["breadcrumbs"]
        values = breadcrumbs.is_a?(Array) ? breadcrumbs : breadcrumbs&.fetch("values", nil)
        return unless values.is_a?(Array)

        values.each do |crumb|
          next unless crumb.is_a?(Hash)

          crumb["data"] = scrub_value(crumb["data"]) if crumb["data"].is_a?(Hash) || crumb["data"].is_a?(Array)
          crumb["message"] = scrub_message(crumb["message"]) if crumb["message"].is_a?(String)
        end
      end

      # Redige i vars dei frame dello stacktrace nel payload conservato.
      def scrub_frames_vars(payload)
        exceptions = payload.dig("exception", "values")
        return unless exceptions.is_a?(Array)

        exceptions.each do |exc|
          frames = exc.is_a?(Hash) ? exc.dig("stacktrace", "frames") : nil
          next unless frames.is_a?(Array)

          frames.each do |frame|
            next unless frame.is_a?(Hash)

            frame["vars"] = scrub_value(frame["vars"]) if frame["vars"].is_a?(Hash) || frame["vars"].is_a?(Array)
          end
        end
      end

      # Copia difensiva dello stacktrace con i soli vars dei frame redatti (per la colonna dedicata).
      def scrub_stacktrace(stacktrace)
        frames = stacktrace["frames"]
        return stacktrace unless frames.is_a?(Array)

        stacktrace.merge("frames" => frames.map do |frame|
          if frame.is_a?(Hash) && (frame["vars"].is_a?(Hash) || frame["vars"].is_a?(Array))
            frame.merge("vars" => scrub_value(frame["vars"]))
          else
            frame
          end
        end)
      end
    end
  end
end
