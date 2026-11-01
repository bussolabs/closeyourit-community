# frozen_string_literal: true

module Secrets
  module Personal
    # Hub unico per l'audit del vault personale: crea un Secrets::Personal::Event append-only. A failed audit
    # never stops a change (rescue + log), but it does stop a read: see FAIL_CLOSED_ACTIONS. Chiamato dai punti di
    # lettura (bundle CLI) e di mutazione (Set/Delete/Import).
    class RecordEvent < ApplicationService
      # A read hands out plaintext: if it cannot be recorded it must not happen (see Secrets::RecordEvent).
      FAIL_CLOSED_ACTIONS = %w[read].freeze

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
        raise if FAIL_CLOSED_ACTIONS.include?(@action.to_s)

        nil
      end
    end
  end
end
