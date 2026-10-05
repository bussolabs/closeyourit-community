# frozen_string_literal: true

module Secrets
  # Snapshot immutabile del valore di una Secrets::Variable ad ogni cambio di PLAINTEXT (versioning +
  # rollback, parità con import esterni). `number` monotòno per variabile; `value` cifrato at-rest come la variabile.
  # Append-only (attr_readonly). Creato da Secrets::Versions::Snapshot, ripristinato da ::Rollback.
  class Version < ApplicationRecord
    belongs_to :secret_variable, class_name: "Secrets::Variable", inverse_of: :versions
    belongs_to :created_by, class_name: "Accounts::Account", optional: true

    attr_readonly :secret_variable_id, :number, :value

    encrypts :value

    validates :number, presence: true, uniqueness: { scope: :secret_variable_id }

    scope :ordered, -> { order(number: :desc) }
  end
end
