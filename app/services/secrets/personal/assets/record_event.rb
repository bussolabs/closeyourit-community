# frozen_string_literal: true

module Secrets
  module Personal
    module Assets
      # Audit dei file segreti personali: a failure never stops a change (rescue + log), but it does
      # stop a download (FAIL_CLOSED_ACTIONS). Salva sempre il nome nel metadata così l'attività resta leggibile anche dopo il
      # purge (asset nullified). Mirror di Secrets::Assets::RecordEvent, account-scoped.
      class RecordEvent
        # A download hands out the plaintext file: if it cannot be recorded it must not happen.
        FAIL_CLOSED_ACTIONS = %w[downloaded].freeze

        def self.call(action:, asset:, metadata: {})
          Secrets::Personal::AssetEvent.create!(
            account: asset.account, organization: asset.organization, asset:, action:,
            metadata: { "name" => asset.name }.merge(metadata.transform_keys(&:to_s))
          )
        rescue StandardError => error
          Rails.logger.error("personal_secret_asset_audit_failed action=#{action} error=#{error.class}")
          raise if FAIL_CLOSED_ACTIONS.include?(action.to_s)
        end
      end
    end
  end
end
