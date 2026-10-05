# frozen_string_literal: true

module Analytics
  # Persiste un batch di misure di velocità in background (coda :ingest). Gemello di
  # `Analytics::IngestJob`: idempotente, progetto cancellato → scarta senza errore, e il `context`
  # contiene SOLO fatti anonimi (tipo di dispositivo, browser, sistema, paese) — mai IP né
  # user-agent grezzo, perché gli argomenti dei job vivono su Postgres.
  class WebVitalsIngestJob < ApplicationJob
    queue_as :ingest

    def perform(project_id:, context:, payload:)
      project = Projects::Project.find_by(id: project_id)
      return if project.nil?

      Analytics::WebVitals::Record.call(project: project, payload: payload, context: context)
    end
  end
end
