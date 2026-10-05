# frozen_string_literal: true

module Analytics
  module Links
    # Revoca (elimina) un link pubblico. Il controller scope-a al progetto visibile (anti-BOLA).
    class Revoke < ApplicationService
      def initialize(link:)
        @link = link
      end

      def call
        @link.project.with_lock do
          @link.project.analytics_links.active.destroy_all
        end
        Result.ok(true)
      end
    end
  end
end
