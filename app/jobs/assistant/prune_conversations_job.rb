# frozen_string_literal: true

module Assistant
  # Pota le conversazioni con l'assistente più vecchie della retention (ultima attività o, per quelle
  # vuote, la creazione). Aiuto effimero, non un archivio. I messaggi spariscono a cascata con la FK.
  # Ricorrente in config/recurring.yml (coda :batch), gemello di Ai::PruneRequestsJob.
  class PruneConversationsJob < ApplicationJob
    queue_as :batch

    def perform
      cutoff = Assistant::Constants::RETENTION_DAYS.days.ago
      Assistant::Conversation
        .where("COALESCE(last_message_at, created_at) < ?", cutoff)
        .in_batches.delete_all
    end
  end
end
