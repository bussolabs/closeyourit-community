# frozen_string_literal: true

module Secrets
  module Shared
    class Delegate < ApplicationService
      include ::Secrets::Github::Syncable

      # `local_name` (CYRA-777) è il nome con cui QUESTO progetto leggerà il valore. nil = il nome
      # del secret dell'organizzazione, cioè come si è sempre comportata ogni delega.
      def initialize(shared_value:, project:, actor: nil, local_name: nil)
        @shared_value, @project, @actor = shared_value, project, actor
        @local_name = local_name.presence
      end

      def call
        delegation = @shared_value.delegations.create!(project: @project, local_name: @local_name)
        Event.create!(organization: @shared_value.organization, shared_variable: @shared_value.shared_variable,
                      environment: @shared_value.environment, project: @project, actor: @actor,
                      action: "delegated", name: @shared_value.name,
                     metadata: { local_name: @local_name }.compact)
        enqueue_github_sync(@project)
        Result.ok(delegation)
      rescue ActiveRecord::RecordInvalid => e
        Result.err(AppError.new(e.message, code: "R422-SHARED-002", details: e.record.errors.as_json))
      end
    end
  end
end
