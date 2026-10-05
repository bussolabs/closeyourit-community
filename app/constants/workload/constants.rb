# frozen_string_literal: true

module Workload
  # Costanti del dominio carico di lavoro (rules/constants.md).
  module Constants
    # CYRA-147 — finestra di preavviso scadenza attività (Workload::Action): entro questa vicinanza alla
    # due_at (o già superata) parte il promemoria workload_due_soon. Il giro è giornaliero, quindi
    # un'attività aperta e scaduta viene ri-ricordata una volta al giorno finché non la si chiude.
    DUE_SOON_THRESHOLD = 1.day

    # Filters that travel with the board | list switch. Status stays out: on the board it is the columns.
    VIEW_SHARED_FILTERS = %w[team_id participant_id has_ticket q].freeze

    # Board columns that start collapsed: cancelled actions are rarely looked at.
    COLLAPSED_BOARD_STATUSES = %w[cancelled].freeze
  end
end
