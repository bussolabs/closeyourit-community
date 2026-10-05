# frozen_string_literal: true

module Logs
  # Collegamento MANUALE tra una voce di log e un errore/ticket (oltre alla correlazione automatica
  # per trace_id). Polimorfico (Errors::Group / Ticketing::Ticket, estensibile). Tenant-integrity: il
  # linkable deve appartenere allo stesso progetto del log. Idempotente (unique su log+linkable).
  class Link < ApplicationRecord
    LINKABLE_TYPES = %w[Errors::Group Ticketing::Ticket].freeze

    belongs_to :log_entry, class_name: "Logs::Entry", inverse_of: :links
    belongs_to :linkable, polymorphic: true
    belongs_to :created_by, class_name: "Accounts::Account", optional: true

    validates :linkable_type, inclusion: { in: LINKABLE_TYPES }
    validates :log_entry_id, uniqueness: { scope: %i[linkable_type linkable_id] }
    validate :linkable_in_same_project

    private

    # Confine di tenant: non si collega un log a un errore/ticket di un altro progetto. Se il tipo non
    # è ammesso (linkable senza project_id) ci pensa la validazione di inclusion: qui si salta.
    def linkable_in_same_project
      return if log_entry.nil? || linkable.nil?
      return unless linkable.respond_to?(:project_id)

      errors.add(:linkable, :invalid) if linkable.project_id != log_entry.project_id
    end
  end
end
