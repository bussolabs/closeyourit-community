# frozen_string_literal: true

module Secrets
  module Overrides
    # Toglie l'override personale di un secret (CYRA-79): da qui in poi quella persona torna a leggere
    # il default del progetto. Il controller risolve la riga nello scope del progetto (anti-BOLA); qui
    # solo la cancellazione e l'audit. Nessun sync GitHub: il push non ha mai visto questo valore.
    class Delete < ApplicationService
      def initialize(override:, actor: nil)
        @override = override
        @actor = actor
      end

      def call
        project = @override.project
        environment = @override.environment
        name = @override.name
        target_account_id = @override.account_id

        @override.destroy!
        ::Secrets::RecordEvent.call(action: "override_deleted", project:, environment:, actor: @actor,
                                    name:, metadata: { target_account_id: })
        Result.ok(@override)
      rescue ActiveRecord::RecordNotDestroyed => e
        Result.err(AppError.new(e.message, code: "R422-SECRET-007"))
      end
    end
  end
end
