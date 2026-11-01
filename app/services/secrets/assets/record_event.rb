# frozen_string_literal: true

module Secrets
  module Assets
    class RecordEvent
      # A download hands out the plaintext file: if it cannot be recorded it must not happen.
      FAIL_CLOSED_ACTIONS = %w[downloaded].freeze

      # `project`/`environment`/`organization` si ricavano dall'asset, che e' il caso normale. Vanno
      # passati a mano solo quando l'asset non c'e': il rifiuto sul caricamento (CYRA-666) avviene prima
      # che il file esista, e senza questi tre il tentativo finirebbe in un evento orfano, cioe' inutile.
      def self.call(action:, actor:, asset: nil, project: nil, environment: nil, organization: nil, metadata: {})
        organization ||= asset&.organization || project&.organization
        Secrets::AssetEvent.create!(organization:, asset:, project: project || asset&.project,
                                    environment: environment || asset&.environment, actor:, action:, metadata:)
      rescue StandardError => error
        Rails.logger.error("secret_asset_audit_failed action=#{action} error=#{error.class}")
        raise if FAIL_CLOSED_ACTIONS.include?(action.to_s)
      end
    end
  end
end
