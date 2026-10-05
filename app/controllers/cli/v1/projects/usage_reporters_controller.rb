# frozen_string_literal: true

module Cli
  module V1
    module Projects
      # CYSK-29 — chi sta mandando usage e da quando: la risposta a «rotta mai chiamata o SDK mai
      # deployato?». Lo scanner la legge PRIMA di giudicare qualunque kind.
      class UsageReportersController < Cli::V1::BaseController
        before_action :set_project!

        def index
          scope = ::Usage::Reporter.where(project_id: @project.id).order(:kind, :sdk_name)
          scope = scope.where(kind: params[:kind].to_s) if params[:kind].present?
          render_ok(::UsageReporterSerializer.new(scope))
        end
      end
    end
  end
end
