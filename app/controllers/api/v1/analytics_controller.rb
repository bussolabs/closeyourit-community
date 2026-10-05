# frozen_string_literal: true

module Api
  module V1
    # Stats API di lettura del progetto del token (bearer): snapshot completo del range (summary,
    # timeseries, breakdown, canali, sessioni, goal). Il :project_id del path deve combaciare col
    # progetto del token (anti-BOLA). Solo lettura.
    class AnalyticsController < Api::V1::BaseController
      # Lettura delle stats del progetto: richiede lo scope 'read' (CYRA-37).
      before_action -> { require_scope!(:read) }

      def show
        # CYRA-738 — il montaggio della fotografia è uno solo per i due canali a token
        # (Analytics::ChannelSnapshot), l'elenco dei filtri ammessi compreso.
        render_ok(::Analytics::ChannelSnapshot.call(
                    project: Current.project, range: params[:range],
                    environment: params[:environment], filters: params.to_unsafe_h
                  ))
      end

      private

      def render_project_scope_mismatch
        render_error("R404-ANALYTICS-001", "Progetto non trovato", status: :not_found)
      end
    end
  end
end
