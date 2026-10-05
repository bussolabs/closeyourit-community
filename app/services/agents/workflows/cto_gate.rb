# frozen_string_literal: true

module Agents
  module Workflows
    module CtoGate
      private

      def effective_cto
        @workflow.project.effective_cto
      end

      def authorized_cto?
        cto = effective_cto
        cto&.human? && cto == @actor && cto.member_of_organization?(@workflow.organization.id) &&
          Authorization::VisibleScope.new(account: cto, organization: @workflow.organization)
                                     .projects.exists?(@workflow.project.id)
      end

      def forbidden
        Result.err(AppError.new("Solo il CTO effettivo può decidere sul piano",
                                code: "R403-WORKFLOW-001", status: :forbidden))
      end
    end
  end
end
