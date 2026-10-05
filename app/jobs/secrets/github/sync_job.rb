# frozen_string_literal: true

module Secrets
  module Github
    # Esegue il push sync verso GitHub in background (coda :ingest). Enfilato dai service di mutazione
    # (dopo il commit) e dalle azioni "Sync now" (web/CLI). Idempotente (le PUT/DELETE secret lo sono).
    #
    # Notifica di sync fallito (CYRA-138, Fase 4 pezzo B): un esito err (config non abilitata,
    # payload invalido, trasporto GitHub in errore...) avvisa i responsabili del progetto — chiamata
    # diretta al dispatch (non un altro job: SyncJob gira già in background, come RotationReminderJob
    # chiama DispatchRotationDue senza un job intermedio). Il "motivo" passato è SEMPRE il codice
    # errore (AppError#code), mai il messaggio libero: vedi Content.for_sync_failure.
    class SyncJob < ApplicationJob
      queue_as :ingest

      def perform(github_repository_id:)
        repository = ::Github::Repository.find_by(id: github_repository_id)
        return if repository.nil?

        result = ::Secrets::Github::Sync.call(repository:)
        return if result.ok?

        # Non loggare il messaggio libero: un errore di trasporto potrebbe contenere input arbitrario.
        # Codice e details sono strutturati; per il dominio secret contengono solo nomi/path/righe.
        Rails.logger.warn(
          "Secrets GitHub sync failed repository_id=#{repository.id} project_id=#{repository.project_id} " \
          "code=#{result.error.code} details=#{result.error.details.to_h.to_json}"
        )
        ::Secrets::Notifications::DispatchSyncFailed.call(project: repository.project, reason: result.error.code)
      end
    end
  end
end
