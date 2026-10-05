# frozen_string_literal: true

module Cli
  module V1
    module ErrorGroups
      # Stato "risolto" come risorsa singleton: PUT = resolve, DELETE = reopen. Gate errors.triage.
      class ResolutionsController < Cli::V1::BaseController
        before_action :set_project!
        before_action -> { require_permission!("errors.triage", scope: @project) }

        # CYRA-192: la resolve accetta `cause` e `fix` — perché l'errore c'era e cosa l'ha chiuso —
        # che la show rilegge. Entrambi opzionali: chi ha fretta chiude e basta. Sulla reopen non si
        # passano e il service li azzera: un gruppo riaperto non è più risolto.
        def update  = render_triage("resolve", cause: params[:cause], fix: params[:fix])
        def destroy = render_triage("reopen")

        private

        # Azione hardcoded e sempre valida → Errors::Triage non può fallire qui: usiamo .value.
        def render_triage(action, **notes)
          group = @project.error_groups.find(params[:error_group_id])
          render_ok(ErrorGroupSerializer.new(Errors::Triage.call(group:, action:, **notes).value))
        end
      end
    end
  end
end
