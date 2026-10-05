# frozen_string_literal: true

module Agents
  # Evidenza durevole di un candidato temporaneamente non lavorabile per uno specifico host in una
  # specifica fase (host+ticket+execution_phase, per-host — decisione CYAU-92). I record restano storici;
  # soltanto retry_at > clock PostgreSQL influenza la coda. L'agent resta valorizzato in compat (la
  # selection firma ancora l'agente fino a CYAU-79/80) ma non è più la chiave di scoping.
  class TicketQueueDeferral < ApplicationRecord
    REASONS = %w[temporary_failure preflight_blocked needs_clarification].freeze
    BACKOFFS = {
      "temporary_failure" => 5.minutes,
      "preflight_blocked" => 30.minutes,
      "needs_clarification" => 6.hours
    }.freeze

    attr_readonly :organization_id, :agent_id, :ticket_id, :host_id, :execution_phase, :reason, :retry_at,
                  :selection_digest, :candidate_version, :repository_fingerprint

    belongs_to :organization,
               class_name: "Organizations::Organization",
               inverse_of: :agent_ticket_queue_deferrals
    belongs_to :ticket,
               class_name: "Ticketing::Ticket",
               inverse_of: :agent_ticket_queue_deferrals
    belongs_to :host,
               class_name: "Agents::Host",
               inverse_of: :ticket_queue_deferrals

    validates :reason, inclusion: { in: REASONS }
    validates :execution_phase, inclusion: { in: Agents::PhaseProfile::PHASES }
    validates :retry_at, :selection_digest, :candidate_version, :repository_fingerprint, presence: true
    # Replay per-host (CYAU-92): il selection token non è host-bound (firma per-agente in compat), quindi
    # lo stesso token da due host produce due deferral distinti → l'unicità del digest è scoped su host.
    validates :selection_digest, uniqueness: { scope: %i[organization_id host_id] }, length: { is: 64 }
    validates :candidate_version, :repository_fingerprint, length: { is: 64 }
    validate :associations_belong_to_organization

    scope :active_at, ->(time) { where("retry_at > ?", time) }

    # Chiave di eleggibilità host-first: host + ticket + fase (per-host). Un defer di una fase non copre
    # altre fasi né altri host; l'indice `index_agent_queue_deferrals_eligibility` la serve.
    def self.active_for(host:, ticket:, execution_phase:, at: Agents::Leases::Clock.current)
      where(host:, ticket:, execution_phase:).active_at(at)
    end

    private

    def associations_belong_to_organization
      return if organization_id.blank?

        errors.add(:host, :invalid) if host&.organization_id.present? && host.organization_id != organization_id
      return unless ticket&.project&.organization_id.present?

      errors.add(:ticket, :invalid) if ticket.project.organization_id != organization_id
    end
  end
end
