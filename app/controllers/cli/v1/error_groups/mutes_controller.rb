# frozen_string_literal: true

module Cli
  module V1
    module ErrorGroups
      # Silenziamento come risorsa singleton: PUT = ignore, DELETE = reopen. Gate errors.triage.
      class MutesController < Cli::V1::BaseController
        before_action :set_project!
        before_action -> { require_permission!("errors.triage", scope: @project) }

        def update  = render_triage("ignore")
        def destroy = render_triage("reopen")

        private

        def render_triage(action)
          group = @project.error_groups.find(params[:error_group_id])
          render_ok(ErrorGroupSerializer.new(Errors::Triage.call(group:, action:).value))
        end
      end
    end
  end
end
