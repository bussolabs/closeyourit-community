# frozen_string_literal: true

module Metrics
  module Groups
    # CYRA-738 — la domanda ai dati della lista dei gruppi-metrica (query e metodi lenti), una sola
    # per i due canali a token. La paginazione resta del canale.
    class Query < ApplicationService
      # Il tipo arriva dai parametri della richiesta: un tipo inesistente si ignora invece di
      # svuotare la lista.
      def initialize(project:, kind: nil)
        @project = project
        @kind = kind
      end

      def call
        scope = @project.metric_groups.recent
        return scope unless Metrics::Group.kinds.key?(@kind)

        scope.where(kind: @kind)
      end
    end
  end
end
