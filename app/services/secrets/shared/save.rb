# frozen_string_literal: true

module Secrets
  module Shared
    class Save < ApplicationService
      include ::Secrets::Github::Syncable

      def initialize(organization:, name:, environment:, value:, actor: nil, description: nil,
                     shared_variable: nil, confirmation_digest: nil, confirmation_effect: :rotate, action: nil,
                     skip_confirmation: false, enqueue_sync: true)
        @organization = organization
        @name = name.to_s.strip.upcase
        @environment = environment
        @value = value.nil? ? nil : value.to_s
        @actor = actor
        @description = description
        @variable = shared_variable
        @confirmation_digest = confirmation_digest
        @confirmation_effect = confirmation_effect
        @action = action
        @skip_confirmation = skip_confirmation
        @enqueue_sync = enqueue_sync
      end

      def call
        value_record = nil
        changed = false
        ApplicationRecord.transaction do
          @variable ||= @organization.shared_secret_variables.find_or_initialize_by(name: @name)
          @variable.created_by ||= @actor
          @variable.description = @description unless @description.nil?
          @variable.save!
          value_record = @variable.values.find_or_initialize_by(environment: @environment)
          changed = value_record.new_record? || value_record.value != @value
          verify_confirmation!(value_record, changed)
          if changed
            value_record.value = @value
            value_record.version_number += 1
            value_record.save!
            value_record.versions.create!(number: value_record.version_number, value: @value, created_by: @actor)
            record_event(@action || (value_record.version_number == 1 ? "created" : "rotated"), value_record)
          end
        end
        enqueue_projects(value_record.projects) if changed && @enqueue_sync
        Result.ok(value_record)
      rescue ActiveRecord::RecordInvalid => e
        Result.err(AppError.new(e.message, code: "R422-SHARED-001", details: e.record.errors.as_json))
      rescue StaleConfirmation => e
        Result.err(AppError.new(e.message, code: "R409-SHARED-001", details: e.impact))
      end

      private

      StaleConfirmation = Class.new(StandardError) { attr_reader :impact; def initialize(impact); @impact = impact; super("Conferma obsoleta"); end }

      def verify_confirmation!(value_record, changed)
        return if @skip_confirmation
        return unless changed && value_record.persisted? && value_record.delegations.exists?
        impact = Impact.call(shared_value: value_record, effect: @confirmation_effect).value
        raise StaleConfirmation, impact unless ActiveSupport::SecurityUtils.secure_compare(@confirmation_digest.to_s, impact["digest"])
      end

      def enqueue_projects(projects)
        projects.includes(:github_repository).distinct.each { |project| enqueue_github_sync(project) }
      end

      def record_event(action, value_record)
        Event.create!(organization: @organization, shared_variable: @variable, environment: @environment,
                      actor: @actor, action:, name: @variable.name, metadata: { version: value_record.version_number })
      end
    end
  end
end
