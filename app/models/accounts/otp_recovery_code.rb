# frozen_string_literal: true

module Accounts
  # Codice di recupero 2FA monouso (CYRA-170). Alternativa al codice TOTP quando l'utente perde
  # l'authenticator. In DB solo il DIGEST SHA-256 (mai il plaintext): il codice in chiaro si mostra
  # una volta sola al setup. La generazione/consumo vive in Accounts::Account (mai callback qui).
  class OtpRecoveryCode < ApplicationRecord
    self.table_name = "accounts_otp_recovery_codes"

    belongs_to :account,
               class_name: "Accounts::Account",
               inverse_of: :otp_recovery_codes

    scope :unused, -> { where(used_at: nil) }

    def used?
      used_at.present?
    end
  end
end
