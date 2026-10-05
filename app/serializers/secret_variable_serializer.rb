# frozen_string_literal: true

# Metadati di una variabile del vault. NON espone MAI `value` (il valore esce solo dall'azione
# `bundle`, gated `secrets.read`), come ProjectTokenSerializer non espone il token_digest.
class SecretVariableSerializer < ApplicationSerializer
  attributes :id, :name, :description, :created_at, :updated_at

  attribute :environment do |variable|
    { id: variable.environment_id, code: variable.environment&.code, label: variable.environment&.label }
  end
end
