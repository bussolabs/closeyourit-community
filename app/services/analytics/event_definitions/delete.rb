# frozen_string_literal: true

module Analytics
  module EventDefinitions
    # Removes a declared event. Stored events keep their data and come back as undeclared (CYRA-1158).
    class Delete < ApplicationService
      def initialize(definition:)
        @definition = definition
      end

      def call
        @definition.destroy
        Result.ok(true)
      end
    end
  end
end
