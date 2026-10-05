# frozen_string_literal: true

module Cli
  module Api
    # Base dei controller CLI (envelope {data}/{error}, niente sessione/redirect-login). NON eredita da
    # ::Api::BaseController (eviterebbe l'ambiguità di costante Cli::Api vs ::Api): prende lo stesso
    # contratto per inclusione, così i due canali non possono più rispondere in forme diverse.
    class BaseController < ActionController::API
      include ApiEnvelope
    end
  end
end
