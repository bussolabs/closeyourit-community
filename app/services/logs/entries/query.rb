# frozen_string_literal: true

module Logs
  module Entries
    # CYRA-738 — ordine e filtri della lista dei log, una volta sola per i due canali a token.
    #
    # Qui l'insieme di partenza NON si costruisce: lo passa il canale, perché i due guardano insiemi
    # legittimamente diversi (le app vedono i log del progetto del token, la riga di comando quelli
    # di tutti i progetti visibili all'account). Quello che era davvero scritto due volte — «dal più
    # recente» più i tre filtri livello/traccia/ambiente — sta qui.
    class Query < ApplicationService
      def initialize(scope:, level: nil, trace_id: nil, environment: nil)
        @scope = scope
        @level = level
        @trace_id = trace_id
        @environment = environment
      end

      def call
        scope = @scope.recent
        # Livello inesistente: si ignora, non svuota la lista (stessa regola degli altri elenchi).
        scope = scope.where(level: @level) if Logs::Entry.levels.key?(@level)
        scope = scope.where(trace_id: @trace_id) if @trace_id.present?
        scope = scope.where(environment: @environment) if @environment.present?
        scope
      end
    end
  end
end
