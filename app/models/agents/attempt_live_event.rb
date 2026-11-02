# frozen_string_literal: true

module Agents
  # One step of an agent at work on a ticket, as the machine running the attempt reported it (CYAU-282).
  # `payload` holds names and counts; review-style code only when the project turned the code view on.
  class AttemptLiveEvent < ApplicationRecord
    KINDS = %w[file_change file_read search command truncated].freeze

    belongs_to :organization, class_name: "Organizations::Organization"
    belongs_to :attempt, class_name: "Agents::Attempt", inverse_of: :live_events

    validates :seq, numericality: { only_integer: true, greater_than: 0 }
    validates :kind, inclusion: { in: KINDS }
  end
end
