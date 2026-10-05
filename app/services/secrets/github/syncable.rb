# frozen_string_literal: true

module Secrets
  module Github
    # Enfila il push sync se il progetto ha un repo GitHub con sync_secrets attivo. Chiamato dai service
    # di mutazione DOPO il commit (mai dentro una transazione: Solid Queue vive su un DB separato, quindi
    # un enqueue in transazione girerebbe prima del commit → stato stantìo).
    module Syncable
      def enqueue_github_sync(project)
        repository = project.github_repository
        return unless repository&.sync_secrets?

        ::Secrets::Github::SyncJob.perform_later(github_repository_id: repository.id)
      end
    end
  end
end
