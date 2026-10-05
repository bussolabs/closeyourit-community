# frozen_string_literal: true

module Seo
  # Dispatcher ricorrente: accoda un giro per ogni sito scaduto. Tiene corto il job ricorrente e
  # isola la visita di ogni sito, come Uptime::DispatchChecksJob.
  #
  # Gira ogni ora, ma la cadenza vera la decide il sito con `next_audit_at`: qui si chiede solo chi
  # è scaduto.
  class DispatchAuditsJob < ApplicationJob
    queue_as :maintenance

    def perform
      Seo::Site.due.find_each { |site| Seo::AuditSiteJob.perform_later(site.id) }
    end
  end
end
