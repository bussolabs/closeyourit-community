# frozen_string_literal: true

module Ai
  # Richiesta AI asincrona (quick bug report, triage monitoring): il controller la crea `pending`
  # e accoda Ai::RunJob; il job esegue il service e scrive l'esito (done + payload / failed + errore);
  # la UI la polla su GET /member/ai/requests/:id. Effimera: Ai::PruneRequestsJob la elimina dopo
  # Ai::Constants::REQUESTS_RETENTION. Scoping per ownership (account), MAI cross-account.
  class Request < ApplicationRecord
    KINDS = %w[ticket_analyze ticket_compose ticket_ask knowledge_ask
               error_triage error_similar metric_triage idea_synthesize].freeze

    # Quale servizio COLLEGATO DALL'ORGANIZZAZIONE serve a ciascuna richiesta (CYRA-548): senza,
    # AiEnqueueing rifiuta prima di creare la riga. Dal CYRA-765 la mappa è VUOTA — l'AI generativa
    # la offre il sistema con una chiave sua, quindi nessun kind pretende più un collegamento e il
    # gate lascia passare tutto.
    #
    # NON è un valore persistito: `ai_requests` non ha una colonna provider, quindi la mappa non
    # descrive nessuna riga già scritta e svuotarla non richiede nessuna migration. Resta scritta
    # perché è il punto in cui il gate chiede «cosa serve a questo kind», e il giorno che tornasse un
    # fornitore da collegare si differenzia qui e in nessun altro posto.
    PROVIDERS = {}.freeze

    def self.provider_for(kind) = PROVIDERS[kind.to_s]

    belongs_to :account, class_name: "Accounts::Account", inverse_of: :ai_requests
    belongs_to :organization, class_name: "Organizations::Organization", inverse_of: :ai_requests

    enum :status, { pending: 0, done: 1, failed: 2 }, prefix: true

    validates :kind, presence: true, inclusion: { in: KINDS }

    scope :for, ->(account:, organization:) { where(account:, organization:) }
    scope :stale, -> { where(created_at: ...Ai::Constants::REQUESTS_RETENTION.ago) }

    def finish_ok!(payload)
      update!(status: :done, payload: payload)
    end

    def finish_err!(code:, message:)
      update!(status: :failed, error_code: code, error_message: message)
    end
  end
end
