# frozen_string_literal: true

module Cli
  module V1
    # Stats API web analytics via token utente (CLI): snapshot completo del range del progetto.
    # Visibilità = gate (nessuna chiave RBAC dedicata, come la dashboard); set_project! anti-BOLA 404.
    class AnalyticsController < Cli::V1::BaseController
      before_action :set_project!

      def show
        # CYRA-738 — stesso montaggio del canale API (Analytics::ChannelSnapshot).
        render_ok(::Analytics::ChannelSnapshot.call(
                    project: @project, range: params[:range],
                    environment: params[:environment], filters: params.to_unsafe_h
                  ))
      end
    end
  end
end
