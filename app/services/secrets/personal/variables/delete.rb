# frozen_string_literal: true

module Secrets
  module Personal
    module Variables
      # Elimina una variabile del vault personale. Il controller la risolve nello scope dell'account
      # (anti-BOLA); qui solo la distruzione + audit.
      class Delete < ApplicationService
        def initialize(variable:)
          @variable = variable
        end

        def call
          account = @variable.account
          organization = @variable.organization
          name = @variable.name

          @variable.destroy!
          Secrets::Personal::RecordEvent.call(action: "deleted", account:, organization:, name:)
          Result.ok(@variable)
        rescue ActiveRecord::RecordNotDestroyed => e
          Result.err(AppError.new(e.message, code: "R422-PERSONALSECRET-002"))
        end
      end
    end
  end
end
