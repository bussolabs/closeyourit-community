# frozen_string_literal: true

module Todos
  # Voce di una lista di todo: titolo + fatto/non-fatto + posizione. Link opzionale a un ticket
  # (tenant-integrity: il ticket dev'essere della stessa org della lista). done + completed_at sono
  # tenuti coerenti da mark/toggle!.
  class Item < ApplicationRecord
    belongs_to :list, class_name: "Todos::List", inverse_of: :items
    belongs_to :ticket, class_name: "Ticketing::Ticket", inverse_of: :todo_items, optional: true

    normalizes :title, with: ->(value) { value.to_s.strip }

    validates :title, presence: true
    validate :ticket_same_organization

    scope :ordered, -> { order(:position, :created_at) }

    # Imposta done a un valore esplicito tenendo coerente completed_at (istante di completamento).
    def mark(done:)
      self.done = done
      self.completed_at = done ? Time.current : nil
    end

    # Flip done ↔ non-done (persistente), tenendo completed_at coerente.
    def toggle!
      mark(done: !done?)
      save!
    end

    private

    # Il ticket linkato (opzionale) dev'essere della STESSA organizzazione della lista: anti-leak
    # cross-tenant (non si linka un ticket di un'altra org). Il ticket porta l'org via project.
    def ticket_same_organization
      return if ticket.blank? || list.blank?

      errors.add(:ticket, :invalid) if ticket.project.organization_id != list.organization_id
    end
  end
end
