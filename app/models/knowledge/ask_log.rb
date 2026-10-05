# frozen_string_literal: true

module Knowledge
  # Storico condiviso delle domande poste a "Chiedi alla KB" (CYRA-421): domanda + risposta + pagine
  # citate, così una domanda già pagata al modello non viene rifatta da zero e il team impara dalle
  # domande degli altri. Diverso da Ai::Request (effimera, per-account): questo è durevole e di team.
  #
  # Porta lo SNAPSHOT dello scope su cui la domanda è stata eseguita (full_access + project_ids/
  # group_ids). La visibilità ricalca ESATTAMENTE quella delle pagine (Knowledge::Page.visible_to):
  # chi non vede un progetto non deve vederne le domande, e le domande org-wide (full_access) le
  # vedono solo gli accessi pieni — altrimenti lo storico esporrebbe contenuto fuori scope.
  class AskLog < ApplicationRecord
    belongs_to :organization, class_name: "Organizations::Organization"
    belongs_to :account, class_name: "Accounts::Account"

    validates :question, presence: true

    scope :recent, -> { order(created_at: :desc) }

    # Registra una domanda conclusa con successo. Chiamata da Ai::RunJob dopo che il RAG ha risposto:
    # normalizza i booleani e le liste così un canale che non passa uno scope non fa saltare i NOT NULL.
    def self.record!(account:, organization:, question:, answer:, insufficient:, full_access:,
                     project_ids:, group_ids:, citations:)
      create!(
        account: account, organization: organization, question: question, answer: answer,
        insufficient: !!insufficient, full_access: !!full_access,
        project_ids: Array(project_ids).compact, group_ids: Array(group_ids).compact,
        citations: citations || []
      )
    end

    # Restricted readers must see every project and group used to produce the answer.
    # Full-access readers can see all answers in their organization.
    def self.visible_to(account:, organization:, full_access: nil, visible_project_ids: nil, visible_group_ids: nil)
      base = where(organization_id: organization.id)
      full_access = Authorization::VisibleScope.unscoped?(account: account, organization: organization) if full_access.nil?
      return base if full_access

      pids = Array(visible_project_ids).compact
      gids = Array(visible_group_ids).compact
      return none if pids.empty? && gids.empty?

      # An answer can combine every source: partial overlap cannot authorize the whole answer.
      scoped = base.where(full_access: false)
        .where("cardinality(project_ids) + cardinality(group_ids) > 0")
      scoped = pids.empty? ? scoped.where("cardinality(project_ids) = 0") :
        scoped.where("project_ids <@ ARRAY[:ids]::uuid[]", ids: pids)
      gids.empty? ? scoped.where("cardinality(group_ids) = 0") :
        scoped.where("group_ids <@ ARRAY[:ids]::uuid[]", ids: gids)
    end
  end
end
