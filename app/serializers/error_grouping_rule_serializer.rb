# frozen_string_literal: true

class ErrorGroupingRuleSerializer < ApplicationSerializer
  attributes :id, :position, :active, :value, :fingerprint_key, :created_at, :updated_at

  # field/operator escono come stringhe leggibili (le chiavi dell'enum), non come interi.
  attribute(:field) { |r| r.field }
  attribute(:operator) { |r| r.operator }
end
