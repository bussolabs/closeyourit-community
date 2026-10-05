# frozen_string_literal: true

module Connections
  # Relazione ticket↔ticket creata dal gate duplicati ("crea e collega"): `ticket` è il nuovo,
  # `related` il preesistente. Direzionale in scrittura, simmetrica in lettura (scope involving:
  # entrambe le show mostrano il collegamento). kind: duplicato quasi-certo vs correlato.
  class TicketLink < ApplicationRecord
    belongs_to :ticket,
               class_name: "Ticketing::Ticket",
               inverse_of: :links
    belongs_to :related,
               class_name: "Ticketing::Ticket",
               inverse_of: :inverse_links
    belongs_to :created_by, class_name: "Accounts::Account"

    # Discriminator chiuso (enum, non lookup): i due valori guidano copy/badge dedicati nel
    # flusso duplicati — un kind nuovo richiederebbe comunque codice (vedi rules/lookup-tables.md).
    enum :kind, { duplicate: 0, related: 1 }, prefix: true

    validates :related_id, uniqueness: { scope: :ticket_id }
    validate :not_self_link
    validate :same_organization

    # Tutti i link che coinvolgono il ticket, da entrambe le direzioni (per la show).
    scope :involving, ->(ticket) { where(ticket_id: ticket.id).or(where(related_id: ticket.id)) }

    # Il capo opposto della relazione rispetto al ticket dato (per renderizzare "collegato a X").
    def other_ticket(ticket)
      ticket_id == ticket.id ? related : self.ticket
    end

    private

    def not_self_link
      errors.add(:related, :invalid) if ticket_id.present? && ticket_id == related_id
    end

    # Integrità tenant: mai un collegamento cross-organizzazione (il gate propone solo ticket
    # visibili della stessa org; qui la difesa in profondità, come TicketVote).
    def same_organization
      return if ticket.blank? || related.blank?

      ticket_org = ticket.project&.organization_id
      related_org = related.project&.organization_id
      return if ticket_org.blank? || related_org.blank?

      errors.add(:related, :invalid) if ticket_org != related_org
    end
  end
end
