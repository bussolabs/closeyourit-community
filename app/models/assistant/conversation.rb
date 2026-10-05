# frozen_string_literal: true

module Assistant
  # Conversazione con l'assistente help, posseduta da un account dentro un'organizzazione (isolamento
  # tenant come Todos::List: nessun RBAC, lo scope .for è anche il confine anti-BOLA per find/destroy).
  # last_message_at è denormalizzato per ordinare la lista "riprendi conversazioni" senza join.
  class Conversation < ApplicationRecord
    belongs_to :account, class_name: "Accounts::Account"
    belongs_to :organization, class_name: "Organizations::Organization"

    # Set when the conversation was opened from a project: every reply reads that project only.
    belongs_to :project, class_name: "Projects::Project", optional: true

    has_many :messages, -> { chronological }, class_name: "Assistant::Message",
                                              inverse_of: :conversation, dependent: :destroy

    # QUALE assistente. Sono due, con regole opposte: `help` (il sito) dice dove andare e ha il
    # divieto esplicito di parlare dei dati, `tools` (il canale CLI) li legge e non conosce le
    # pagine. Senza distinguerli, la storia di uno finirebbe nel prompt dell'altro e ogni canale
    # potrebbe cancellare i thread dell'altro. Non è una tabella nuova perché la forma è identica:
    # cambia solo chi risponde.
    enum :kind, { help: 0, tools: 1 }, prefix: :kind

    normalizes :title, with: ->(value) { value.to_s.strip.presence }

    # Attività recente prima; le conversazioni senza messaggi (last_message_at nil) in coda.
    scope :ordered, -> { order(Arel.sql("last_message_at DESC NULLS LAST"), created_at: :desc) }

    # Conversazioni dell'account nell'org (possedute). Anti-BOLA per find/destroy.
    #
    # `kind` fa parte del confine, non è un filtro di comodo: senza, il canale CLI aprirebbe (e
    # cancellerebbe) i thread nati nel sito. Chi non lo passa vede tutto, come prima — è il canale
    # web, che di conversazioni con attrezzi non ne ha.
    def self.for(account:, organization:, kind: nil)
      scope = where(account_id: account.id, organization_id: organization.id)
      kind ? scope.where(kind: kind) : scope
    end
  end
end
