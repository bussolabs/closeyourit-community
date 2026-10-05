# frozen_string_literal: true

module Agents
  module Leases
    def self.table_name_prefix = "agents_leases_"

    # Memoria durevole di una lease conclusa: impedisce a un acquire ritardato dello stesso run di
    # resuscitare lavoro già rilasciato, senza occupare l'unica riga lease attiva del ticket.
    class Tombstone < ApplicationRecord
      attr_readonly :organization_id, :ticket_id, :host_id, :account_id, :run_id, :released_at

      belongs_to :organization,
                 class_name: "Organizations::Organization",
                 inverse_of: :agent_lease_tombstones
      belongs_to :ticket,
                 class_name: "Ticketing::Ticket",
                 inverse_of: :agent_lease_tombstones
      belongs_to :host,
                 class_name: "Agents::Host",
                 inverse_of: :lease_tombstones,
                 optional: true
      belongs_to :account,
                 class_name: "Accounts::Account",
                 optional: true

      validates :run_id, :released_at, presence: true
      validates :run_id, length: { maximum: 255 }
      validate :associations_belong_to_organization
      validate :exactly_one_holder

      # Il tombstone eredita il titolare del lease che chiude: la memoria del rilascio è per-titolare,
      # altrimenti il release di una persona impedirebbe a un host di riprendere lo stesso ticket.
      def self.record!(lease:, released_at:)
        create_or_find_by!(ticket: lease.ticket, host: lease.host, account: lease.account,
                           run_id: lease.run_id) do |tombstone|
          tombstone.organization = lease.organization
          tombstone.released_at = released_at
        end
      end

      private

      # Il tombstone NON verifica che il titolare account sia ancora membro dell'organizzazione, a
      # differenza del lease. È un record storico: dice "questa lavorazione ha già rilasciato", un
      # fatto che resta vero anche se poi la persona esce dal team. Pretendere la membership corrente
      # renderebbe impossibile scrivere il tombstone di un lease scaduto di un ex membro, e siccome
      # Acquire tombstona PRIMA di passare la riga al titolare successivo, quel ticket resterebbe
      # occupato da un lease morto per sempre.
      def associations_belong_to_organization
        return if organization_id.blank?

        errors.add(:host, :invalid) if host&.organization_id.present? && host.organization_id != organization_id
        return unless ticket&.project&.organization_id.present?

        errors.add(:ticket, :invalid) if ticket.project.organization_id != organization_id
      end

      # Gemello del check_constraint agents_leases_tombstones_holder. Vedi Agents::Lease#exactly_one_holder.
      def exactly_one_holder
        return if host_id.present? ^ account_id.present?

        errors.add(:base, :invalid_holder)
      end
    end
  end
end
