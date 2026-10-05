# frozen_string_literal: true

module Uptime
  # Banner della status page pubblica di un monitor (manutenzioni/avvisi). Uno per monitor (indice
  # unico su monitor_id): livello (colore), messaggio, finestra opzionale start/end, flag attivo.
  # È "live" (mostrato) solo se attivo e dentro la finestra — vedi live?.
  class Announcement < ApplicationRecord
    self.table_name = "uptime_announcements"

    belongs_to :monitor, class_name: "Uptime::Monitor", inverse_of: :announcement
    belongs_to :created_by, class_name: "Accounts::Account", optional: true

    enum :level, { info: 0, maintenance: 1, warning: 2 }

    normalizes :message, with: ->(value) { value.to_s.strip }

    validates :message, presence: true
    validate :ends_after_starts

    scope :enabled, -> { where(active: true) }

    # Mostrato ORA? attivo + dentro la finestra (estremi nil = illimitato).
    def live?(now = Time.current)
      active? &&
        (starts_at.nil? || starts_at <= now) &&
        (ends_at.nil? || now <= ends_at)
    end

    private

    def ends_after_starts
      return if starts_at.blank? || ends_at.blank?

      errors.add(:ends_at, :after_start) if ends_at <= starts_at
    end
  end
end
