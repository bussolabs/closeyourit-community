# frozen_string_literal: true

module Metrics
  # Occorrenza immutabile di una metrica lenta (solo created_at). project_id denormalizzato per
  # retention/scoping senza join sul gruppo. Idempotente su sample_id (replay/at-least-once).
  class Sample < ApplicationRecord
    # CYRA-750 — la tabella è divisa a fette mensili su `created_at`: da qui la chiave primaria
    # riportata a `id` e il gemello per la scrittura in blocco.
    include PartitionedTable

    belongs_to :group, class_name: "Metrics::Group", inverse_of: :samples
    belongs_to :project, class_name: "Projects::Project", inverse_of: :metric_samples

    enum :kind, { slow_query: 0, slow_method: 1, performance_issue: 2 }, prefix: true

    validates :sample_id, presence: true, uniqueness: { scope: :project_id }
    validates :occurred_at, presence: true
    validates :duration_ms, presence: true
  end
end
