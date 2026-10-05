# frozen_string_literal: true

module Analytics
  # Persiste un batch di pageview in background (coda :ingest). Idempotente (Record deduplica su
  # event_id); progetto cancellato → scarta senza errore. Il `context` contiene SOLO fatti anonimi
  # (visitor_hash/browser/os) — MAI IP o User-Agent raw: gli argomenti dei job vivono su Postgres.
  class IngestJob < ApplicationJob
    queue_as :ingest

    def perform(project_id:, context:, payload:)
      project = Projects::Project.find_by(id: project_id)
      return if project.nil?

      Analytics::Ingest::Record.call(project: project, payload: payload, context: context)
    end
  end
end
