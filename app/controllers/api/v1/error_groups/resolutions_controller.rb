# frozen_string_literal: true

module Api
  module V1
    module ErrorGroups
      # Stato "risolto" di un gruppo come risorsa singleton: PUT = resolve, DELETE = reopen.
      class ResolutionsController < Api::V1::BaseController
        # Il triage degli errori richiede lo scope 'read' (accesso alla telemetria): un token
        # ingest-only non gestisce i gruppi (CYRA-37).
        before_action -> { require_scope!(:read) }

        def update  = triage("resolve")
        def destroy = triage("reopen")

        private

        # L'azione è hardcoded e sempre valida → Errors::Triage non può fallire qui: usiamo .value.
        def triage(action)
          group = Current.project.error_groups.find(params[:error_group_id])
          render_ok(ErrorGroupSerializer.new(Errors::Triage.call(group:, action:).value))
        end
      end
    end
  end
end
