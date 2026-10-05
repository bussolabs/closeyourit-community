# frozen_string_literal: true

module Github
  # Processing asincrono dei webhook GitHub (thin → service, pattern Errors::IngestJob). Dispatch per
  # tipo di evento (X-GitHub-Event); eventi non gestiti = no-op. Ogni handler è idempotente (GitHub può
  # ritentare la consegna).
  class WebhookJob < ApplicationJob
    queue_as :ingest

    def perform(event:, payload:)
      case event
      when "push"         then Github::Webhooks::Push.call(payload:)
      when "create"       then Github::Webhooks::Create.call(payload:)
      when "release"      then Github::Webhooks::Release.call(payload:)
      when "installation" then Github::Webhooks::Installation.call(payload:)
      when "pull_request" then Github::Webhooks::PullRequest.call(payload:)
      end
    end
  end
end
