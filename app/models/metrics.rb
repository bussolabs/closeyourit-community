# frozen_string_literal: true

module Metrics
  # Dominio telemetria di performance (query/metodi lenti). Tabelle prefissate `metrics_`.
  def self.table_name_prefix
    "metrics_"
  end
end
