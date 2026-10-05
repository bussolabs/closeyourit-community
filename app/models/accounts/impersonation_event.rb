# frozen_string_literal: true

module Accounts
  # Audit di un'impersonazione: quale god ha impersonato quale account, da quando a quando.
  class ImpersonationEvent < ApplicationRecord
    self.table_name = "accounts_impersonation_events"

    belongs_to :god, class_name: "Accounts::Account"
    belongs_to :account, class_name: "Accounts::Account"

    scope :open, -> { where(ended_at: nil) }

    def close!
      update!(ended_at: Time.current)
    end
  end
end
