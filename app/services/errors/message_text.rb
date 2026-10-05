# frozen_string_literal: true

module Errors
  module MessageText
    def self.read(payload)
      legacy = text(payload["message"])
      legacy.nil? ? text(payload["logentry"]) : legacy
    end

    def self.text(value)
      return value if value.is_a?(String)
      return unless value.is_a?(Hash)

      [ value["formatted"], value["message"] ].find { |item| item.is_a?(String) }
    end
  end
end
