# frozen_string_literal: true

module Secrets
  module Personal
    # Hub unico per l'audit del vault personale: crea un Secrets::Personal::Event append-only. Fire-and-forget
    # — un audit che fallisce NON deve rompere una lettura/mutazione (rescue + log). Chiamato dai punti di
    # lettura (bundle CLI) e di mutazione (Set/Delete/Import).
    class RecordEvent < ApplicationService
      def initialize(action:, account:, organization:, name: nil, metadata: {})
        @action = action
        @account = account
        @organization = organization
        @name = name
        @metadata = metadata
      end

      def call
        Secrets::Personal::Event.create!(
          action: @action,
          account: @account,
          organization: @organization,
          name: @name,
          metadata: @metadata
        )
      rescue StandardError => e
        Rails.logger.warn("Personal secrets audit event failed: #{e.class} #{e.message}")
        nil
      end
    end
  end
end
