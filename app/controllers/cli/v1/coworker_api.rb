# frozen_string_literal: true

module Cli
  module V1
    # Shared gate of the Puck endpoints: closed where Coworkers is not available, scoped to the
    # Puckies the token's person can open (CYRA-1022).
    module CoworkerApi
      extend ActiveSupport::Concern

      included do
        before_action :require_coworkers
      end

      private

      def require_coworkers
        render_error("R404-COWORKERS-001", "Coworkers is not available", status: :not_found) unless
          ::Coworkers.available_to?(account: Current.account, organization: Current.organization)
      end

      def coworker_puckies
        Authorization::VisibleScope.new(account: Current.account, organization: Current.organization).coworker_puckies
      end

      def coworker_puck = @coworker_puck ||= coworker_puckies.find(params[:coworker_id])
    end
  end
end
