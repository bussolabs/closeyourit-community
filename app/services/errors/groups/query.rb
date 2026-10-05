# frozen_string_literal: true

module Errors
  module Groups
    # CYRA-738 — la domanda ai dati della lista dei gruppi d'errore, una sola per i due canali a
    # token (Api::V1 bearer di progetto, Cli::V1 token utente). Stavano scritte due volte e le due
    # copie erano già divergenti: solo quella della riga di comando preloadava l'assegnatario, che
    # il serializer stampa su OGNI riga — quindi il canale delle app faceva una lettura in più per
    # gruppo. Il preload sta qui, dove nessuno dei due può dimenticarselo.
    #
    # La paginazione resta del canale: le due liste hanno contratti diversi (la meta dell'envelope
    # la monta la base di ciascun canale) e non è la domanda ai dati.
    class Query < ApplicationService
      # Lo stato arriva dai parametri della richiesta: uno stato inesistente si ignora, non svuota
      # la lista — chi scrive `?status=risolto` deve vedere tutto, non zero righe senza spiegazione.
      def initialize(project:, status: nil)
        @project = project
        @status = status
      end

      def call
        scope = @project.error_groups.includes(:assignee).recent
        return scope unless Errors::Group.statuses.key?(@status)

        scope.where(status: @status)
      end
    end
  end
end
