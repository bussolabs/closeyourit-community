# frozen_string_literal: true

module Projects
  # Milestone della roadmap di UN progetto (es. "v2.0", "Q3 2026"): scoped al progetto, perché
  # progetti diversi hanno release/avanzamenti indipendenti. code unico per progetto, data target
  # opzionale (due_on). CRUD admin/owner sul progetto. I ticket vi si agganciano via milestone_id
  # (nullify alla cancellazione: il ticket sopravvive senza milestone).
  class Milestone < ApplicationRecord
    self.table_name = "projects_milestones"

    belongs_to :project,
               class_name: "Projects::Project",
               inverse_of: :milestones
    belongs_to :created_by,
               class_name: "Accounts::Account",
               optional: true

    has_many :tickets,
             class_name: "Ticketing::Ticket",
             foreign_key: :milestone_id,
             inverse_of: :milestone,
             dependent: :nullify

    # Activity-log generalizzato (polimorfico): cronologia create/update della milestone.
    has_many :activity_events,
             class_name: "Activity::Event",
             as: :subject,
             dependent: :destroy

    # Radice di tenancy della milestone = il progetto (delega, non colonna).
    delegate :organization_id, to: :project

    normalizes :code, with: ->(code) { code.strip.downcase.gsub(/\s+/, "_") }
    normalizes :label, with: ->(label) { label.strip }

    validates :code, presence: true,
              format: { with: /\A[a-z][a-z0-9_]*\z/ },
              uniqueness: { scope: :project_id }
    validates :label, presence: true
    validates :color, presence: true

    scope :active, -> { where(active: true) }
    # Ordina per data target (milestone con data prima, crescente; quelle senza in fondo), poi posizione/label.
    scope :ordered, -> { order(Arel.sql("due_on ASC NULLS LAST"), :position, :label) }

    EMPTY_PROGRESS = { percent: 0, done_weight: 0, total_weight: 0, done_count: 0, total_count: 0 }.freeze

    # Avanzamento PESATO (somma weight) con FALLBACK conteggio (ticket senza weight = 1) per N
    # milestone in 1 query (niente N+1 nella lista). "done" = status categoria done.
    # → { milestone_id => { percent:, done_weight:, total_weight:, done_count:, total_count: } }.
    def self.progress_for(milestone_ids)
      ids = Array(milestone_ids).compact.uniq
      return {} if ids.blank?

      done = Types::TicketStatus.categories[:done]
      result = ids.index_with { EMPTY_PROGRESS.dup }
      Ticketing::Ticket.joins(:status).where(milestone_id: ids).group(:milestone_id).pluck(
        :milestone_id,
        Arel.sql("COALESCE(SUM(COALESCE(ticketing_tickets.weight, 1)), 0)"),
        Arel.sql("COALESCE(SUM(COALESCE(ticketing_tickets.weight, 1)) FILTER (WHERE types_ticket_statuses.category = #{done}), 0)"),
        Arel.sql("COUNT(*)"),
        Arel.sql("COUNT(*) FILTER (WHERE types_ticket_statuses.category = #{done})")
      ).each do |mid, total_w, done_w, total_c, done_c|
        # simplecov:disable total_w = SUM(COALESCE(weight,1)) su un GROUP con ≥1 ticket → sempre ≥1; `total_w.zero?` (percent 0) irraggiungibile
        result[mid] = { percent: total_w.zero? ? 0 : (done_w.to_f / total_w * 100).round,
                        done_weight: done_w, total_weight: total_w, done_count: done_c, total_count: total_c }
        # simplecov:enable
      end
      result
    end

    # Avanzamento della singola milestone (delega al batch).
    def progress = self.class.progress_for([ id ])[id]
  end
end
