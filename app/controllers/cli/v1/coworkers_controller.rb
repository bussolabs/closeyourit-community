# frozen_string_literal: true

module Cli
  module V1
    # The Puckies of the token's person in the token's organization, for the apps (CYRA-1022).
    class CoworkersController < Cli::V1::BaseController
      include CoworkerApi

      def index
        render_ok(CoworkerPuckSerializer.new(coworker_puckies.order(:name).to_a))
      end
    end
  end
end
