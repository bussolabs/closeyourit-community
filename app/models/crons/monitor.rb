# frozen_string_literal: true

module Crons
  # Heartbeat monitor di un job schedulato: si aspetta un check-in ogni `expected_interval_minutes`.
  # Se non arriva entro intervallo + `grace_minutes` → `missed` (alert). Copre la classe di guasti
  # oggi cieca: un job che smette silenziosamente di girare. Nasce al primo check-in (zero config).
  # `status` è salute gestita dal sistema (workflow tecnico) → enum legittimo (rules/lookup-tables.md).
  class Monitor < ApplicationRecord
    self.table_name = "crons_monitors"

    belongs_to :project, class_name: "Projects::Project", inverse_of: :cron_monitors
    belongs_to :environment, class_name: "Types::Environment", optional: true
    has_many :check_ins, class_name: "Crons::CheckIn", foreign_key: :monitor_id,
             inverse_of: :monitor, dependent: :destroy

    # CYRA-696 — `failing` è il lavoro che PARTE puntuale e finisce male, distinto da `missed`, che è
    # il lavoro che non è partito affatto. Valori SOLO in append: il 3 è di missed.
    enum :status, { unknown: 0, ok: 1, late: 2, missed: 3, failing: 4 }, prefix: :status

    normalizes :slug, with: ->(value) { value.to_s.strip.downcase }

    validates :slug, presence: true, uniqueness: { scope: :project_id }
    validates :name, presence: true
    validates :expected_interval_minutes, numericality: { only_integer: true, greater_than: 0 }
    validates :grace_minutes, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

    scope :enabled, -> { where(enabled: true) }
    scope :recent, -> { order(:name) }

    # Scaduto = nessun check-in entro intervallo + grazia (guardato da now).
    def overdue?(now = Time.current)
      return false unless enabled?
      return true if last_check_in_at.nil?   # atteso ma mai arrivato

      last_check_in_at < now - (expected_interval_minutes + grace_minutes).minutes
    end

    def deadline
      return nil if last_check_in_at.nil?

      last_check_in_at + (expected_interval_minutes + grace_minutes).minutes
    end

    # CYRA-484 — da QUANDO dura lo stato attuale. Per un lavoro in ritardo o mancato è il momento in
    # cui è scaduta la tolleranza (non l'ultimo check-in: quello era ancora un successo); per un
    # lavoro sano è l'ultimo check-in andato bene. Nessun check-in mai arrivato → non si sa, e dire
    # «da sempre» sarebbe una bugia.
    def status_since
      return nil if last_check_in_at.nil?
      return deadline if status_late? || status_missed?

      last_check_in_at
    end
  end
end
