# frozen_string_literal: true

module Clusters
  module Namespaces
    # Links a namespace to a project (and optionally one of the environments it declares): alerts on
    # its workloads then reach the people following that project (CYAG-22).
    class Link < ApplicationService
      def initialize(namespace:, project:, environment: nil)
        @namespace = namespace
        @project = project
        @environment = environment
      end

      def call
        return refuse("Project of another organization") if @project.organization_id != @namespace.cluster.organization_id
        return refuse("Environment not declared by the project") if @environment && !declared?

        @namespace.update!(project: @project, environment: @environment)
        Result.ok(@namespace)
      end

      private

      def declared? = Connections::ProjectEnvironment.exists?(project: @project, environment: @environment)

      def refuse(message)
        Result.err(AppError.new(message, code: "R422-CLUSTER-003", status: :unprocessable_content))
      end
    end
  end
end
