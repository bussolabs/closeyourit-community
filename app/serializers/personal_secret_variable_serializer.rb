# frozen_string_literal: true

# Metadati di una variabile del vault PERSONALE. NON espone MAI `value` (il valore esce solo dall'azione
# `bundle`), come SecretVariableSerializer non espone il valore nelle liste.
class PersonalSecretVariableSerializer < ApplicationSerializer
  attributes :id, :name, :description, :created_at, :updated_at
end
