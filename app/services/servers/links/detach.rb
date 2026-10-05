# frozen_string_literal: true

module Servers
  module Links
    # Scollega un host da un environment di progetto.
    class Detach < ApplicationService
      def initialize(link:)
        @link = link
      end

      def call
        @link.destroy
        Result.ok(true)
      end
    end
  end
end
