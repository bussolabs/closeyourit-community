# frozen_string_literal: true

module Certification
  module BootstrapSupport
    ACTIONS = %w[create create_installation_sessions cleanup_installation_sessions inspect_installation_receipt inspect cleanup retention measurement_credentials evaluate_measurements inspect_measurements].freeze
    EXCEPTIONS = %w[ActiveRecord::RecordInvalid ActiveRecord::RecordNotUnique ActiveRecord::RecordNotFound ArgumentError RuntimeError StandardError].freeze
    ATTRIBUTES = %w[password email handle name account project organization base].freeze

    def self.password
      "#{SecureRandom.base64(48)}Aa1!"
    end

    def self.failure(error, action)
      attributes = error.is_a?(ActiveRecord::RecordInvalid) && error.record ? error.record.errors.attribute_names.map(&:to_s) : []
      { error: { code: "bootstrap_failed", stage: ACTIONS.include?(action) ? action : "unknown",
        exception_class: EXCEPTIONS.include?(error.class.name) ? error.class.name : "StandardError",
        validation_attributes: ATTRIBUTES & attributes } }
    end
  end
end
