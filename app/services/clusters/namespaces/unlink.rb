# frozen_string_literal: true

module Clusters
  module Namespaces
    # Removes the project link of a namespace (CYAG-22).
    class Unlink < ApplicationService
      def initialize(namespace:)
        @namespace = namespace
      end

      def call
        @namespace.update!(project: nil, environment: nil)
        Result.ok(@namespace)
      end
    end
  end
end
