# frozen_string_literal: true

module Member
  module Monitoring
    # CYRA-800 — quello che la lista, lo smistamento e l'unione dei gruppi di errore condividono
    # davvero: come si risolve il gruppo dell'indirizzo e chi può metterci le mani.
    module ErrorGroupScoping
      extend ActiveSupport::Concern

      private

      # Anti-BOLA + scoping: gruppo non visibile (altra org o progetto non assegnato) → RecordNotFound.
      def set_group
        @group = visible.error_groups.find(params[:id])
      end

      # Promuovere a ticket è una chiave PROPRIA: aprire un ticket non è smistare un errore.
      def require_triage_role
        key = action_name == "promote" ? "errors.promote" : "errors.triage"
        require_permission!(key, scope: @group.project)
      end
    end
  end
end
