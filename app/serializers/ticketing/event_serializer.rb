# frozen_string_literal: true

module Ticketing
  # One history row for the CLI: who, what, when, and `data` as stored, so edits keep their full
  # before and after. CYRA-1309
  class EventSerializer < ApplicationSerializer
    attributes :id, :action, :actor_name, :created_at, :data

    attribute(:impersonated) { |event| event.impersonated? }
  end
end
