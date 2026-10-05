# frozen_string_literal: true

module Workload
  # Una action = un'attività non-dev registrata su un team. Natura libera (titolo/descrizione, nessun
  # enum-tipo). Può opzionalmente legarsi a un Ticketing::Ticket (link esistente o generato via
  # Workload::Actions::PromoteToTicket) — FK nullable, mai ereditarietà. Il team è la radice di tenancy
  # E di visibilità: un utente vede/gestisce solo le actions dei team a cui appartiene.
  class Action < ApplicationRecord
    belongs_to :team,
               class_name: "Teams::Team",
               inverse_of: :workload_actions
    belongs_to :created_by,
               class_name: "Accounts::Account",
               optional: true,
               inverse_of: false
    belongs_to :ticket,
               class_name: "Ticketing::Ticket",
               optional: true,
               inverse_of: :workload_actions

    has_many :participations,
             class_name: "Connections::WorkloadParticipant",
             foreign_key: :action_id,
             inverse_of: :action,
             dependent: :destroy
    has_many :participants, through: :participations, source: :account

    # Activity-log generalizzato (polimorfico): cronologia create/update della action.
    has_many :activity_events,
             class_name: "Activity::Event",
             as: :subject,
             dependent: :destroy

    # Radice di tenancy della action = il team, non il progetto (unica delle cinque aree).
    delegate :organization_id, to: :team

    # Il team di una action è immutabile: spostarla cambierebbe chi la vede (BOLA). Vedi PromoteToTicket
    # e Save (team_id settato solo alla creazione).
    attr_readonly :team_id

    normalizes :title, with: ->(title) { title.strip }
    normalizes :description, with: ->(description) { description.to_s.strip }

    validates :title, presence: true
    validate :ticket_same_organization

    enum :status, { planned: 0, in_progress: 1, done: 2, cancelled: 3 }, prefix: :status

    scope :ordered, -> { order(Arel.sql("scheduled_at DESC NULLS LAST"), created_at: :desc) }
    scope :by_status, ->(status) { where(status: status) }

    # CYRA-147 — attività in scadenza: ANCORA aperte (planned/in_progress), con una due_at valorizzata
    # imminente (entro la soglia) o già superata. Le chiuse (done/cancelled) e quelle senza scadenza
    # restano fuori: il promemoria di scadenza non deve suonare su ciò che è concluso o senza data.
    scope :due_soon, ->(at: Time.current) {
      where(status: %i[planned in_progress])
        .where.not(due_at: nil)
        .where(due_at: ..(at + Workload::Constants::DUE_SOON_THRESHOLD))
    }

    # Actions visibili all'account nell'org = quelle dei team a cui appartiene. Gemello di
    # Authorization::VisibleScope#workload_actions e di Chat::Conversation.visible_to.
    def self.visible_to(account:, organization:)
      where(team_id: account.teams.where(organization_id: organization.id).select(:id))
    end

    private

    # Un ticket linkato deve stare nella stessa org del team della action (tenant integrity),
    # come Todos::Item#ticket_same_organization (che confronta via list.organization_id).
    def ticket_same_organization
      return if ticket.blank? || team.blank?

      errors.add(:ticket, :invalid) if ticket.project.organization_id != team.organization_id
    end
  end
end
