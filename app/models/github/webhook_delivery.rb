# frozen_string_literal: true

module Github
  # Permanent receipts survive installation deletion; only unfinished receipts keep their body.
  class WebhookDelivery < ApplicationRecord
    class ConflictingDelivery < StandardError; end

    RETRY_AFTER = 10.minutes

    scope :recoverable, -> { where(completed_at: nil).where("enqueued_at IS NULL OR enqueued_at < ?", RETRY_AFTER.ago) }

    def self.receive(delivery_id:, event:, body:)
      digest = Digest::SHA256.hexdigest(body)
      transaction(requires_new: true) do
        create!(delivery_id: delivery_id.presence, body_digest: digest, event:, body:)
      end
    rescue ActiveRecord::RecordNotUnique
      existing = find_by(body_digest: digest)
      return existing if existing

      # A reused unsigned identifier must never overwrite a previously authenticated body.
      raise ConflictingDelivery, "GitHub delivery identifier reused with different content"
    end

    def enqueue
      with_lock(requires_new: true) do
        return if completed_at || (enqueued_at && enqueued_at >= RETRY_AFTER.ago)

        job = Github::WebhookJob.perform_later(delivery_id: id)
        update!(enqueued_at: Time.current) if job && job.successfully_enqueued?
      end
    rescue StandardError => error
      Rails.logger.error("[github.webhook.enqueue] #{error.class} receipt=#{id}")
      false
    end

    def process
      with_lock(requires_new: true) do
        return if completed_at

        yield event, parsed_payload
        update!(completed_at: Time.current, body: nil)
      end
    end

    private

    def parsed_payload
      parsed = JSON.parse(body)
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end
  end
end
