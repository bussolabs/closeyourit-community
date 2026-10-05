# frozen_string_literal: true

module Projects
  module CoverageReports
    # CYRA-738 — l'estratto di copertura pubblicato dalla CI, riletto dai due canali a token con la
    # stessa domanda: per ramo, ordinato per nome del ramo.
    class Query < ApplicationService
      def initialize(project:, branch: nil)
        @project = project
        @branch = branch.to_s.strip
      end

      def call
        scope = @project.coverage_reports.order(:branch)
        return scope if @branch.blank?

        scope.where(branch: @branch)
      end
    end
  end
end
