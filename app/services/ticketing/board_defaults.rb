# frozen_string_literal: true

module Ticketing
  # Default delle colonne RIDOTTE per una board mai configurata (CYRA-691). Prima il default
  # ripiegava TUTTE le colonne concluse: chi arrivava per «cosa è stato consegnato» — un cliente
  # esterno, tipicamente senza preferenze salvate — trovava chiusa esattamente quella metà. Ora una
  # colonna conclusa parte ridotta solo se nella finestra recente non ha niente da mostrare.
  #
  # È la fonte UNICA del default: la leggono la board e la materializzazione al primo
  # tocco (Member::Tickets::CollapsedColumnsController). Se divergessero, espandere una colonna ne
  # ripiegherebbe un'altra alla visita successiva. Di proposito NON guarda filtri né ricerca: il
  # default deve essere stabile per la persona, non per la vista del momento.
  module BoardDefaults
    def self.collapsed_codes(statuses, tickets)
      done = statuses.select(&:category_done?)
      return Set.new if done.empty?

      with_recent = tickets.where(status_id: done.map(&:id))
                           .where(closed_at: Constants::BOARD_DONE_WINDOW.ago..)
                           .distinct.pluck(:status_id).to_set
      done.reject { |status| with_recent.include?(status.id) }.map(&:code).to_set
    end
  end
end
