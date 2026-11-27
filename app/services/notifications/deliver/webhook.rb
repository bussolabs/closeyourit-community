# frozen_string_literal: true

require "net/http"
require "openssl"
require "zlib"

module Notifications
  class Deliver
    # One bounded, signed request; the caller owns retries. Temporary failures are R502-ALERT-001,
    # definitive refusals are R422-ALERT-004, and programming errors propagate. CYRA-1227
    class Webhook < ApplicationService
      OPEN_TIMEOUT = 3
      READ_TIMEOUT = 5
      TRANSPORT_FAILURES = [ EOFError, Net::HTTPBadResponse, Net::ProtocolError,
                             Errno::EADDRNOTAVAIL, Zlib::Error ].freeze

      def initialize(channel:, event_type:, subject:, content:, occurred_at: nil, delivery_id: nil)
        @channel = channel
        @event_type = event_type
        @subject = subject
        @content = content
        @occurred_at = occurred_at
        @delivery_id = delivery_id
      end

      def call
        if DevelopmentLab.organization?(@channel.organization)
          Rails.logger.info("Development lab webhook intercepted")
          return Result.ok(:lab_intercepted)
        end

        uri = URI.parse(@channel.webhook_url)
        # Ri-verifica a delivery-time E risolve UNA volta l'IP pubblico da pinnare: la validazione
        # config-time non copre i cambi DNS, e ri-risolvere l'host al connect riaprirebbe il TOCTOU.
        addresses = resolved_addresses(uri)
        return unsafe if addresses.nil? || addresses.any? { |addr| NetworkGuard.blocked_address?(addr) }
        # A resolver that does not answer is the network failing for a moment, not a refusal. CYRA-1227
        return transient("Webhook host irrisolvibile") if addresses.empty?

        address = addresses.first

        body = payload.to_json
        response = post(uri, address, body)
        status = response.code.to_i
        return Result.ok(status) if status.between?(200, 299)

        Rails.logger.warn("Alerting webhook #{@channel.id} → HTTP #{response.code}")
        return transient("Webhook HTTP #{response.code}") if TransientFailure::RETRYABLE_STATUSES.include?(status)

        definitive("Webhook HTTP #{response.code}")
      rescue BoundedHttp::ResponseTooLarge, URI::InvalidURIError => e
        definitive("Webhook fallito: #{e.class}")
      rescue StandardError => e
        raise unless TransientFailure === e || TRANSPORT_FAILURES.any? { |type| e.is_a?(type) }

        Rails.logger.warn("Alerting webhook #{@channel.id} fallito: #{e.class} #{e.message}")
        transient("Webhook irraggiungibile")
      end

      private

      def transient(message)
        Result.err(AppError.new(message, code: "R502-ALERT-001", status: :bad_gateway))
      end

      def definitive(message)
        Result.err(AppError.new(message, code: "R422-ALERT-004"))
      end

      def payload
        {
          # Same id on every attempt of one queued delivery: a receiver drops the duplicate. CYRA-1227
          delivery_id: @delivery_id,
          event_type: @event_type,
          title: @content.title,
          body: @content.body,
          url: @content.url,
          # Gli eventi org-scoped (server_* e agents_*) non hanno progetto: `project` diventa null nel JSON
          # invece di far esplodere il dereferenziamento (NoMethodError catturato dal rescue → webhook
          # mai consegnato). Il ricevente gestisce l'assenza del campo.
          project: project_payload,
          subject: { type: @subject.class.name, id: @subject.id },
          # Event time is frozen; send time and its signature describe this attempt. CYRA-1227
          occurred_at: (@occurred_at || Time.current).iso8601,
          sent_at: Time.current.iso8601
        }
      end

      def project_payload
        return nil if @content.project.nil?

        { id: @content.project.id, key: @content.project.key, name: @content.project.name }
      end

      def unsafe
        Result.err(AppError.new("Webhook URL non sicura", code: "R422-ALERT-002"))
      end

      # Indirizzi dell'host risolti UNA volta (il primo viene pinnato), nil se schema o host non sono
      # contattabili. Stesso criterio di NetworkGuard.resolved_public_address: un solo indirizzo interno
      # basta a rifiutare; la lista vuota resta distinta per poter ritentare.
      def resolved_addresses(uri)
        return nil unless %w[http https].include?(uri.scheme) && uri.host.present?
        return [ uri.host ] if NetworkGuard.ip_literal?(uri.host)

        NetworkGuard.resolve(uri.host)
      end

      def post(uri, address, body)
        http = Net::HTTP.new(uri.host, uri.port)
        http.ipaddr = address   # connessione all'IP GIÀ validato; Host header/SNI/verifica cert restano su uri.host
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = OPEN_TIMEOUT
        http.read_timeout = READ_TIMEOUT

        request = Net::HTTP::Post.new(uri.request_uri)
        request["Content-Type"] = "application/json"
        request["X-CloseYourIt-Event"] = @event_type
        request["X-CloseYourIt-Delivery"] = @delivery_id if @delivery_id.present?
        if @channel.webhook_secret.present?
          request["X-CloseYourIt-Signature"] =
            "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", @channel.webhook_secret, body)}"
        end
        request.body = body
        BoundedHttp.request(http, request, max_bytes: 64.kilobytes, timeout: OPEN_TIMEOUT + READ_TIMEOUT)
      end
    end
  end
end
