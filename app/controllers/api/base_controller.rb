# frozen_string_literal: true

module Api
  # Base di TUTTI i controller API. Eredita da ActionController::API (NON da ApplicationController:
  # niente Authentication a sessione/redirect-login, niente allow_browser). Envelope {data:}/{error:}
  # e resa degli errori arrivano da ApiEnvelope, che è lo stesso contratto della riga di comando.
  class BaseController < ActionController::API
    include ApiEnvelope
  end
end
