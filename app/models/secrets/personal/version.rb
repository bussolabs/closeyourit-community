# frozen_string_literal: true

module Secrets
  module Personal
    # Snapshot immutabile del valore di una Secrets::Personal::Variable ad ogni cambio di PLAINTEXT
    # (versioning + rollback). `number` monotòno per variabile; `value` cifrato at-rest come la variabile.
    # Append-only (attr_readonly). Creato da Secrets::Personal::Versions::Snapshot, ripristinato da ::Rollback.
    class Version < ApplicationRecord
      belongs_to :variable, class_name: "Secrets::Personal::Variable", inverse_of: :versions

      attr_readonly :variable_id, :number, :value

      encrypts :value

      validates :number, presence: true, uniqueness: { scope: :variable_id }

      scope :ordered, -> { order(number: :desc) }
    end
  end
end
