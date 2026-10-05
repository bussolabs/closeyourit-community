# frozen_string_literal: true

module Uptime
  # Uno step della timeline di un incident narrato (detected → investigating → fixing → monitoring →
  # resolved). Umano (created_by, opzionale per resistere alla cancellazione account); body opzionale,
  # precompilato lato UI con un testo standard editabile. Pattern Ticketing::Event (semplificato).
  class IncidentUpdate < ApplicationRecord
    self.table_name = "uptime_incident_updates"

    belongs_to :incident, class_name: "Uptime::Incident", inverse_of: :updates
    belongs_to :created_by, class_name: "Accounts::Account", optional: true

    enum :phase, { detected: 0, investigating: 1, fixing: 2, monitoring: 3, resolved: 4 }

    normalizes :body, with: ->(value) { value.to_s.strip.presence }

    validates :phase, presence: true

    scope :chronological, -> { order(:created_at, :id) }
  end
end
