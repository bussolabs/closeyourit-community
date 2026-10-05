# frozen_string_literal: true

module Cli
  module V1
    module Projects
      # CYSK-26 — rilettura da riga di comando dell'estratto di copertura pubblicato dalla CI. Sola
      # lettura: la visibilità del progetto È il gate, come per la show del progetto e la guidance.
      # Anti-BOLA: il progetto si risolve in visible_projects (fuori scope / altra org → R404).
      class CoverageReportsController < Cli::V1::BaseController
        before_action :set_project!

        def index
          # CYRA-738 — stessa domanda ai dati del canale API (Projects::CoverageReports::Query).
          reports = ::Projects::CoverageReports::Query.call(project: @project, branch: params[:branch])
          render_ok(::CoverageReportSerializer.new(reports))
        end
      end
    end
  end
end
