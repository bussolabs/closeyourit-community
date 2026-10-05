# frozen_string_literal: true

require "net/http"
require "openssl"

module Notifications
  class Deliver
    # Consegna su webhook generico: POST JSON firmato (HMAC-SHA256 del body con il secret del canale,
    # header X-CloseYourIt-Signature) — il ricevente verifica la firma prima di fidarsi. Fire-and-forget:
    # timeout corto, nessun retry, l'errore viene loggato e non blocca il resto della pipeline.
    class Webhook < ApplicationService
      OPEN_TIMEOUT = 3
      READ_TIMEOUT = 5

      def initialize(channel:, event_type:, subject:, content:)
        @channel = channel
        @event_type = event_type
        @subject = subject
        @content = content
      end

      def call
        if DevelopmentLab.organization?(@channel.organization)
          Rails.logger.info("Development lab webhook intercepted")
          return Result.ok(:lab_intercepted)
        end

        uri = URI.parse(@channel.webhook_url)
        # Ri-verifica a delivery-time E risolve UNA volta l'IP pubblico da pinnare: la validazione
        # config-time non copre i cambi DNS, e ri-risolvere l'host al connect riaprirebbe il TOCTOU.
        address = safe_public_address(uri)
        return Result.err(AppError.new("Webhook URL non sicura", code: "R422-ALERT-002")) if address.nil?

        body = payload.to_json
        response = post(uri, address, body)
        if response.code.to_i.between?(200, 299)
          Result.ok(response.code.to_i)
        else
          Rails.logger.warn("Alerting webhook #{@channel.id} → HTTP #{response.code}")
          Result.err(AppError.new("Webhook HTTP #{response.code}", code: "R502-ALERT-001", status: :bad_gateway))
        end
      rescue StandardError => e
        Rails.logger.warn("Alerting webhook #{@channel.id} fallito: #{e.class} #{e.message}")
        Result.err(AppError.new("Webhook irraggiungibile", code: "R502-ALERT-001", status: :bad_gateway))
      end

      private

      def payload
        {
          event_type: @event_type,
          title: @content.title,
          body: @content.body,
          url: @content.url,
          # Gli eventi org-scoped (server_* e agents_*) non hanno progetto: `project` diventa null nel JSON
          # invece di far esplodere il dereferenziamento (NoMethodError catturato dal rescue → webhook
          # mai consegnato). Il ricevente gestisce l'assenza del campo.
          project: project_payload,
          subject: { type: @subject.class.name, id: @subject.id },
          sent_at: Time.current.iso8601
        }
      end

      def project_payload
        return nil if @content.project.nil?

        { id: @content.project.id, key: @content.project.key, name: @content.project.name }
      end

      # Ritorna l'IP pubblico da pinnare, o nil se lo schema non è http(s) o l'host è interno/irrisolvibile.
      def safe_public_address(uri)
        return nil unless %w[http https].include?(uri.scheme)

        NetworkGuard.resolved_public_address(uri.host)
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
