# frozen_string_literal: true

module Api
  # Ingest Sentry-compatibile (drop-in): gli SDK sentry-* puntano qui cambiando solo SENTRY_DSN.
  # Path /api/:project_id/{envelope,store} (dettato dagli SDK, FUORI da /api/v1). Auth via DSN
  # public key. Risponde 200 {"id": event_id} subito dopo l'enqueue (persistenza async nel job).
  class IngestController < Api::BaseController
    include IngestAuthentication

    before_action :authenticate_ingest!
    before_action :validate_content_encoding!
    before_action :enforce_origin_allowlist! # difesa browser aggiuntiva (CYRA-109), dopo l'auth
    before_action :mark_ingest_authorized!

    around_action :bound_crash_requests, only: :minidump

    rescue_from ::Crashes::Rejected do |error|
      status = error.message == "request_too_large" ? :content_too_large : :unprocessable_content
      code = status == :content_too_large ? "R413-CRASH-001" : "R422-CRASH-001"
      render_error(code, error.message, status: status)
    end
    rescue_from ::Crashes::Unavailable do
      render_error("R503-CRASH-001", "Crash processing or storage is temporarily unavailable", status: :service_unavailable)
    end

    # Formato moderno (NDJSON envelope) usato da tutti gli SDK sentry-* correnti.
    def envelope
      parser = Errors::Ingest::EnvelopeParser.new(body: request.body)
      result = parser.call
      return render_error(result.error.code, result.error.message, status: result.error.status) if result.err?

      unless envelope_dsn_matches?(parser.dsn)
        return render_error("R401-AUTH-001", "Conflicting envelope DSN", status: :unauthorized)
      end

      if parser.attachments.any?
        admit_attachments(result.value, parser.attachments, event_id: parser.event_id)
      end

      counts = parser.ignored_counts.sort.to_h
      response.set_header("X-CloseYourIt-Ignored-Items", counts.to_json) if counts.any?
      sessions = ::SessionHealth::Ingest::Record.call(project: Current.project, items: parser.session_items)
      response.set_header("X-CloseYourIt-Session-Results", sessions.to_h.to_json) if parser.session_items.any?
      event_id = enqueue_all(result.value)
      ActiveSupport::Notifications.instrument("sentry.ingest", accepted: result.value.size, accepted_sessions: sessions.accepted, session_results: sessions.to_h, ignored: counts)
      render json: { id: event_id }
    rescue ActiveRecord::ActiveRecordError
      render_error("R503-INGEST-001", "Session storage is temporarily unavailable", status: :service_unavailable)
    end

    # Endpoint legacy /store: il body è un singolo evento JSON (eventualmente gzip).
    # Stessi limiti dimensione dell'envelope (anti gzip-bomb) → R413.
    def store
      raw = request.body.read(Errors::Ingest::EnvelopeParser::MAX_COMPRESSED + 1).to_s.b
      return payload_too_large if raw.bytesize > Errors::Ingest::EnvelopeParser::MAX_COMPRESSED

      payload = parse_json(raw)
      return payload_too_large if payload == :too_large
      # un body JSON valido ma non-oggetto (es. `42`, `[..]`) non è un evento: R422, non un 500 da TypeError.
      return render_error("R422-INGEST-001", "Evento malformato", status: :unprocessable_content) unless Errors::Ingest::EventPayload.valid?(payload)

      enqueue(payload)
      render json: { id: payload["event_id"] }
    end

    def minidump
      raise ::Crashes::Unavailable unless Rails.configuration.x.crash_ingestion_enabled
      event, items = ::Crashes::Multipart.call(body: request.body, content_type: request.content_type)
      event["event_id"] ||= SecureRandom.hex(16)
      events = event.empty? ? [] : [ event ]
      outcome = admit_attachments(events, items, event_id: event["event_id"])
      raise ::Crashes::Rejected, "invalid_minidump" if outcome.report.nil? || outcome.report.manifest.empty?
      enqueue_all(events)
      render json: { id: event["event_id"] }
    rescue ActiveRecord::ActiveRecordError
      render_error("R503-CRASH-001", "Crash storage is temporarily unavailable", status: :service_unavailable)
    end

    private

    def bound_crash_requests
      reserved = false
      begin
        ::Crashes::REQUEST_SLOTS.push(true, true)
        reserved = true
      rescue ThreadError
        response.set_header("Retry-After", "1")
        render_error("R503-CRASH-001", "Crash ingestion capacity reached", status: :service_unavailable)
        return
      end
      yield
    ensure
      ::Crashes::REQUEST_SLOTS.pop if reserved
    end

    def admit_attachments(events, items, event_id:)
      unless Rails.configuration.x.crash_ingestion_enabled
        response.set_header("X-CloseYourIt-Attachment-Results", { accepted: 0, duplicates: 0, rejected: items.size, diagnostics: { feature_disabled: items.size } }.to_json)
        return ::Crashes::Record::Outcome.new(accepted: 0, duplicates: 0, rejected: items.size, diagnostics: { "feature_disabled" => items.size }, report: nil)
      end
      raise ::Crashes::Rejected, "ambiguous_event_identity" if events.size > 1
      event = events.first || { "event_id" => event_id }
      event["event_id"] ||= event_id || SecureRandom.hex(16)
      canonicalize_crash_identity!(event)
      outcome = ::Crashes::Record.call(project: Current.project, event: event, items: items)
      response.set_header("X-CloseYourIt-Attachment-Results", outcome.to_h.except(:report).to_json)
      if outcome.report&.manifest&.any?
        event["platform"] ||= "native"
        event["level"] ||= "fatal"
        event["message"] ||= "Native crash (symbols unavailable)"
        event["exception"] ||= { "values" => [ { "type" => "NativeCrash", "value" => outcome.report.manifest.dig("crash_info", "type") || "Native crash", "mechanism" => { "type" => "minidump", "handled" => false } } ] }
        events << event if events.empty?
      end
      outcome
    end

    def canonicalize_crash_identity!(event)
      identifier = event["event_id"].to_s
      identifier = identifier.delete("-") if identifier.match?(/\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/i)
      event["event_id"] = identifier.downcase if ::Crashes::EVENT_ID.match?(identifier)
    end

    def envelope_dsn_matches?(dsn)
      return true if dsn.nil?

      uri = URI.parse(dsn)
      identifiers = [ Current.project.id.to_s, Current.project.sentry_project_id.to_s ]
      %w[http https].include?(uri.scheme) && uri.user == Current.api_token.public_key &&
        identifiers.include?(uri.path.split("/").last)
    rescue URI::InvalidURIError
      false
    end

    def validate_content_encoding!
      encoding = request.headers["Content-Encoding"].to_s.downcase
      return if [ "", "identity", "gzip" ].include?(encoding)

      render_error("R415-INGEST-001", "Unsupported content encoding", status: :unsupported_media_type)
    end

    def enqueue_all(events)
      first_id = nil
      events.each do |payload|
        next unless Errors::Ingest::EventPayload.valid?(payload) # un item JSON non-oggetto non deve far crashare l'intero batch

        first_id ||= payload["event_id"]
        enqueue(payload)
      end
      first_id
    end

    def enqueue(payload)
      Errors::Ingest::Enqueue.call(project: Current.project, payload: payload)
    end

    def parse_json(raw)
      max = Errors::Ingest::EnvelopeParser::MAX_DECOMPRESSED
      data = Errors::Ingest::EnvelopeParser.gunzip_limited(raw, max)
      return :too_large if data.bytesize > max

      JSON.parse(data)
    rescue JSON::ParserError, Zlib::Error
      nil
    end

    def payload_too_large
      render_error("R413-INGEST-001", "Payload troppo grande", status: :content_too_large)
    end
  end
end
