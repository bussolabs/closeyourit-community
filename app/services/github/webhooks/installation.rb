# frozen_string_literal: true

module Github
  module Webhooks
    # Evento `installation`: la creazione passa dal callback di connessione (che sa a quale org legarla);
    # qui si gestisce solo la DISINSTALLAZIONE (action deleted) → rimuove l'installazione e, a cascata, i
    # repo agganciati dei progetti dell'org.
    class Installation < Base
      def call
        installation&.destroy if value_at(@payload, "action") == "deleted"

        Result.ok(nil)
      end
    end
  end
end
