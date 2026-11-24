# frozen_string_literal: true

require "openssl"
require "json"

module Github
  # Authenticate the raw body before recording a permanent receipt or enqueueing work.
  class WebhooksController < ActionController::API
    SIGNATURE_HEADER = "X-Hub-Signature-256"
    EVENT_HEADER = "X-GitHub-Event"

    before_action :verify_signature

    def create
      delivery = Github::WebhookDelivery.receive(
        delivery_id: request.headers["X-GitHub-Delivery"],
        event: request.headers[EVENT_HEADER].to_s, body: request.raw_post
      )
      delivery.enqueue
      head :no_content
    rescue Github::WebhookDelivery::ConflictingDelivery
      head :conflict
    end

    private

    def verify_signature
      secret = Settings::Integrations.value(:gh_webhook_secret).to_s
      given = request.headers[SIGNATURE_HEADER].to_s
      expected = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", secret, request.raw_post)}"
      return if secret.present? && ActiveSupport::SecurityUtils.secure_compare(given, expected)

      head :not_found
    end
  end
end
