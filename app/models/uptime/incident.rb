# frozen_string_literal: true

module Uptime
  # Finestra di downtime di un monitor: aperta (resolved_at nil) mentre è down, chiusa al recovery.
  # Più finestre grezze possono essere UNIFICATE in un incident logico "narrato": il primary
  # (parent_id nil) raggruppa i figli (foglie) e porta la timeline umana — phase corrente + gli
  # step in `updates`. La finestra pubblica è l'UNIONE self+figli (vedi window_*).
  class Incident < ApplicationRecord
    self.table_name = "uptime_incidents"

    belongs_to :monitor, class_name: "Uptime::Monitor", inverse_of: :incidents
    belongs_to :parent, class_name: "Uptime::Incident", optional: true, inverse_of: :children
    has_many :children, class_name: "Uptime::Incident", foreign_key: :parent_id,
             inverse_of: :parent, dependent: :nullify
    has_many :updates, class_name: "Uptime::IncidentUpdate", foreign_key: :incident_id,
             inverse_of: :incident, dependent: :destroy

    # Stato UMANO corrente della narrazione (nil = nessuna narrazione ancora). `prefix: :phase` per
    # NON generare `resolved?` in conflitto con `def resolved?` (basato su resolved_at, stato MACCHINA).
    enum :phase, { detected: 0, investigating: 1, fixing: 2, monitoring: 3, resolved: 4 }, prefix: :phase

    validates :started_at, presence: true
    validate :parent_same_monitor
    validate :parent_is_top_level

    scope :open, -> { where(resolved_at: nil) }
    scope :recent, -> { order(started_at: :desc) }
    # Incident di primo livello (non figli di un raggruppamento): le righe "reali" da mostrare.
    scope :top_level, -> { where(parent_id: nil) }

    def ongoing? = resolved_at.nil?
    def resolved? = resolved_at.present?
    def duration_seconds = ((resolved_at || Time.current) - started_at).to_i

    # Narrazione presente? (almeno una phase impostata) → mostra timeline + badge phase.
    def narrated? = phase.present?
    def grouped? = children.any?

    # Finestra UNIONE (self + figli): inizio = min degli started_at.
    def window_started_at
      [ started_at, *children.map(&:started_at) ].compact.min
    end

    # Fine finestra unione: nil se una qualsiasi finestra (self o figlio) è ancora aperta,
    # altrimenti il max dei resolved_at.
    def window_resolved_at
      parts = [ self, *children ]
      return nil if parts.any?(&:ongoing?)

      parts.filter_map(&:resolved_at).max
    end

    def window_ongoing? = window_resolved_at.nil?

    def window_duration_seconds = ((window_resolved_at || Time.current) - window_started_at).to_i

    private

    # Un incident può raggruppare solo finestre dello STESSO monitor.
    def parent_same_monitor
      return if parent.blank?

      errors.add(:parent, :invalid) if parent.monitor_id != monitor_id
    end

    # Grouping a un solo livello: il parent dev'essere top-level (niente catene padre→figlio→nipote).
    def parent_is_top_level
      return if parent.blank?

      errors.add(:parent, :invalid) if parent.parent_id.present?
    end
  end
end
