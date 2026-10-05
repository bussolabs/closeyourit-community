# frozen_string_literal: true

module Replays
  # Persiste i chunk di session replay in background (coda :ingest): comprime gli eventi rrweb e li
  # allega alla sessione (ActiveStorage). Fire-and-forget dal controller; se il progetto è stato
  # cancellato, scarta senza errore.
  class IngestJob < ApplicationJob
    queue_as :ingest

    def perform(project_id:, payload:)
      project = Projects::Project.find_by(id: project_id)
      return if project.nil?

      Replays::Ingest::Record.call(project: project, chunks: payload)
    end
  end
end
