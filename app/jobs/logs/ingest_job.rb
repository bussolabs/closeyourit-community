# frozen_string_literal: true

module Logs
  # Persiste un batch di log in background (coda :ingest). Idempotente (Record deduplica su event_id);
  # se il progetto è stato cancellato, scarta senza errore.
  class IngestJob < ApplicationJob
    queue_as :ingest

    def perform(project_id:, payload:)
      project = Projects::Project.find_by(id: project_id)
      return if project.nil?

      Logs::Ingest::Record.call(project: project, payload: payload)
    end
  end
end
