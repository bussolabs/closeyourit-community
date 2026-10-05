# frozen_string_literal: true

module Errors
  # Persiste un evento Sentry in background (coda :ingest) leggendo il payload dalla staging effimera
  # (Errors::IngestPayload): in coda viaggia solo l'id, mai il corpo (CYRA-211). Idempotente
  # (Ingest::Record deduplica su event_id); staging assente (già processata, potata, o progetto
  # cancellato a cascata) → no-op; dopo aver persistito, cancella la riga di staging.
  class IngestJob < ApplicationJob
    queue_as :ingest
    retry_on ::Ingest::EventLock::Busy, wait: :polynomially_longer, attempts: 10

    # `project_id`/`payload` sono la firma PRE-CYRA-211: li accettiamo per il deploy rolling, così un job
    # accodato da un web vecchio e raccolto da un worker nuovo (o viceversa) non fallisce con
    # ArgumentError e non perde l'evento. Ramo transitorio, rimovibile quando la coda si è svuotata dei
    # job pre-deploy.
    def perform(payload_id: nil, project_id: nil, payload: nil)
      return persist(Projects::Project.find_by(id: project_id), payload) if payload_id.nil?

      staged = Errors::IngestPayload.find_by(id: payload_id)
      return if staged.nil?

      persist(staged.project, staged.payload, user_hash: staged.user_hash)
      staged.destroy
    end

    private

    def persist(project, payload, user_hash: nil)
      Errors::Ingest::Record.call(project: project, payload: payload, staged_user_hash: user_hash) if project
    end
  end
end
