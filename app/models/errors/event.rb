# frozen_string_literal: true

module Errors
  # Occorrenza immutabile di un errore (solo created_at, nessun updated_at). Conserva il payload
  # Sentry raw lossless; project_id è denormalizzato per retention/scoping senza join sul gruppo.
  class Event < ApplicationRecord
    self.table_name = "errors_events"
    # CYRA-750 — la tabella è divisa a fette mensili su `created_at`: da qui la chiave primaria
    # riportata a `id` e il gemello per la scrittura in blocco.
    include PartitionedTable

    belongs_to :group, class_name: "Errors::Group", inverse_of: :events
    belongs_to :project, class_name: "Projects::Project", inverse_of: :error_events

    enum :level, { debug: 0, info: 1, warning: 2, error: 3, fatal: 4 }, prefix: true

    validates :event_id, presence: true, uniqueness: { scope: :project_id }
    validates :occurred_at, presence: true
  end
end
