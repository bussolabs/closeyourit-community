# frozen_string_literal: true

module Agents
  # CYRA-746 — le relazioni fra un ticket e la sua automazione vivono QUI, nel dominio che le
  # possiede, non dentro `Ticketing::Ticket`. Il ticket si limita a includere il concern: quando
  # gli agenti imparano un pezzo nuovo (una presa in carico diversa, un altro registro di rinvii)
  # cambia questo file, non il modello che tutto il prodotto attraversa.
  #
  # Il verso della dipendenza è quello che conta: `Ticketing` non nomina più nessuna classe
  # `Agents::`, mentre `Agents` nomina il ticket — che è il dato di partenza di ogni lavorazione
  # automatica. Le classi restano riferite per NOME (stringa): il concern non le carica al momento
  # dell'inclusione, quindi non nasce nessun anello di caricamento fra i due domini.
  module TicketAutomatable
    extend ActiveSupport::Concern

    included do
      # Le FK fanno cascade dentro il DELETE del ticket: nessun callback AR lease→ticket, così ogni
      # mutazione conserva l'ordine di lock ticket→lease usato dai service concorrenti.
      has_one :agent_lease,
              class_name: "Agents::Lease",
              foreign_key: :ticket_id,
              inverse_of: :ticket,
              dependent: nil
      has_one :agent_workflow,
              class_name: "Agents::Workflow",
              foreign_key: :ticket_id,
              inverse_of: :ticket,
              dependent: :destroy
      has_many :agent_lease_tombstones,
               class_name: "Agents::Leases::Tombstone",
               foreign_key: :ticket_id,
               inverse_of: :ticket,
               dependent: nil
      has_many :agent_ticket_queue_deferrals,
               class_name: "Agents::TicketQueueDeferral",
               foreign_key: :ticket_id,
               inverse_of: :ticket,
               dependent: nil
    end
  end
end
