# frozen_string_literal: true

# Metadati di una variabile del vault CONDIVISO (org-level). NON espone MAI `value` (il valore vive su
# Secrets::Shared::Value, una riga per environment, e non esce mai dalle liste), come
# PersonalSecretVariableSerializer non espone il valore del vault personale.
class SharedSecretVariableSerializer < ApplicationSerializer
  attributes :id, :name, :description, :created_at, :updated_at
end
