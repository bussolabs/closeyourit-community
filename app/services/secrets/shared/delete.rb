# frozen_string_literal: true

module Secrets
  module Shared
    class Delete < ApplicationService
      include ::Secrets::Github::Syncable

      def initialize(shared_variable:, actor: nil, confirmation_digests:)
        @variable, @actor = shared_variable, actor
        @confirmation_digests = Array(confirmation_digests).sort
      end

      def call
        impacts = @variable.values.map { |value| Impact.call(shared_value: value, effect: :delete).value }
        expected = impacts.map { |impact| impact["digest"] }.sort
        unless expected == @confirmation_digests
          return Result.err(AppError.new("Conferma obsoleta", code: "R409-SHARED-001", details: impacts))
        end
        projects = @variable.values.flat_map { |value| value.projects.to_a }.uniq
        attributes = { organization: @variable.organization, actor: @actor, action: "deleted", name: @variable.name }
        ApplicationRecord.transaction do
          @variable.destroy!
          Event.create!(attributes)
        end
        projects.each { |project| enqueue_github_sync(project) }
        Result.ok(@variable)
      end
    end
  end
end
