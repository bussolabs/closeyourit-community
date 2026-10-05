# frozen_string_literal: true

require "openssl"
require "json"

module Github
  # Webhook inbound della GitHub App (canale Github::, rules/backend-channels.md). Machine POST JSON:
  # eredita da ActionController::API (niente CSRF né allow_browser). Il gate è la firma HMAC
  # X-Hub-Signature-256 = "sha256="+HMAC-SHA256(GH_WEBHOOK_SECRET, raw body), confrontata in tempo
  # costante. Firma errata/assente → 404 (nasconde l'endpoint). Su firma valida accoda il processing
  # su Solid Queue e risponde SEMPRE 204 (anche sugli eventi ignorati), così GitHub non ritenta.
  class WebhooksController < ActionController::API
    SIGNATURE_HEADER = "X-Hub-Signature-256"
    EVENT_HEADER = "X-GitHub-Event"

    before_action :verify_signature

    def create
      Github::WebhookJob.perform_later(event: request.headers[EVENT_HEADER].to_s, payload: parsed_payload)
      head :no_content
    end

    private

    def verify_signature
      secret = Settings::Integrations.value(:gh_webhook_secret).to_s
      given = request.headers[SIGNATURE_HEADER].to_s
      expected = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", secret, request.raw_post)}"
      return if secret.present? && ActiveSupport::SecurityUtils.secure_compare(given, expected)

      head :not_found
    end

    # Il payload è il body grezzo (lo stesso su cui è calcolata la firma), non i params Rails. Un corpo
    # illeggibile, o che è JSON valido ma non un oggetto, vale come consegna vuota: la firma dice DA CHI
    # viene la consegna, non com'è fatta dentro, e gli handler a valle si aspettano un oggetto (CYRA-720).
    def parsed_payload
      parsed = JSON.parse(request.raw_post)
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end
  end
end
