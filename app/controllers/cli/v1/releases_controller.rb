# frozen_string_literal: true

module Cli
  module V1
    # Release del progetto (sola lettura, canale CLI). Scope = release del progetto VISIBILE
    # (set_project! → visibilità Fase E, anti-BOLA 404). Le release nascono dall'ingest CI su /api/v1,
    # non si creano da CLI. Nessuna chiave RBAC (read = visibilità di scope).
    class ReleasesController < Cli::V1::BaseController
      before_action :set_project!

      def index
        # CYRA-738 — stessa domanda ai dati del canale API (Projects::Releases::Query).
        records, meta = paginate(::Projects::Releases::Query.call(project: @project))
        render_ok(ReleaseSerializer.new(records), meta: meta)
      end
    end
  end
end
