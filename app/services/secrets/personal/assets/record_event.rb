# frozen_string_literal: true

module Secrets
  module Personal
    module Assets
      # Audit fire-and-forget dei file segreti personali: non deve MAI rompere il flusso principale
      # (rescue + log). Salva sempre il nome nel metadata così l'attività resta leggibile anche dopo il
      # purge (asset nullified). Mirror di Secrets::Assets::RecordEvent, account-scoped.
      class RecordEvent
        def self.call(action:, asset:, metadata: {})
          Secrets::Personal::AssetEvent.create!(
            account: asset.account, organization: asset.organization, asset:, action:,
            metadata: { "name" => asset.name }.merge(metadata.transform_keys(&:to_s))
          )
        rescue StandardError => error
          Rails.logger.error("personal_secret_asset_audit_failed action=#{action} error=#{error.class}")
        end
      end
    end
  end
end
