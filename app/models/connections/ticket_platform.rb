# frozen_string_literal: true

module Connections
  # Join ticket ↔ piattaforma: piattaforme colpite dal bug. Il vincolo "subset delle piattaforme
  # del progetto" è validato sul model Ticketing::Ticket (errore singolo e chiaro).
  class TicketPlatform < ApplicationRecord
    belongs_to :ticket,
               class_name: "Ticketing::Ticket",
               inverse_of: :ticket_platforms
    belongs_to :platform,
               class_name: "Types::Platform",
               inverse_of: :ticket_platforms

    validates :platform_id, uniqueness: { scope: :ticket_id }
  end
end
