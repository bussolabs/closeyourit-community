# frozen_string_literal: true

module Activity
  # Evento del log attività GENERALIZZATO (polimorfico): cronologia per entità non-ticket
  # (Projects::Project, Projects::Group, …) tramite `subject`. I ticket usano Ticketing::Event
  # (più ricco). `organization_id` denormalizzato per scoping di tenant come Ticketing::Event.
  class Event < ApplicationRecord
    ACTIONS = %w[created updated moved_in moved_out].freeze

    belongs_to :organization, class_name: "Organizations::Organization"
    belongs_to :subject, polymorphic: true
    belongs_to :actor, class_name: "Accounts::Account", optional: true
    belongs_to :true_actor, class_name: "Accounts::Account", optional: true

    validates :action, inclusion: { in: ACTIONS }
    validate :organization_matches_subject

    # Tie-break su id: a parità di created_at l'ordine resta deterministico.
    scope :chronological, -> { order(:created_at, :id) }

    # L'attore reale differisce da quello percepito → azione in impersonation.
    def impersonated? = true_actor_id.present? && true_actor_id != actor_id

    private

    # Confine di tenant: l'org dell'evento deve combaciare con quella del subject.
    def organization_matches_subject
      return if subject.nil? || !subject.respond_to?(:organization_id)
      # The source keeps its record of a move after the subject has left (CYRA-879).
      return if action == "moved_out"

      errors.add(:organization, :invalid) if organization_id != subject.organization_id
    end
  end
end
