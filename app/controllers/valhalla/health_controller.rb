# frozen_string_literal: true

module Valhalla
  # Cruscotto di salute tecnica del sistema (god-only, gate ereditato da BaseController): backlog e
  # falliti SolidQueue, tabelle in crescita sul primary, stato dei servizi esterni collegati. Thin come
  # DashboardController: tutta la query logic vive nel presenter.
  class HealthController < BaseController
    # CYRA-924 — the three tables sort on their columns (C9), each on its own param.
    BACKLOG_SORT_COLUMNS = { "queue" => ->(row) { row.queue_name.to_s }, "backlog" => ->(row) { row.count } }.freeze
    FAILED_SORT_COLUMNS = { "job" => ->(row) { row.class_name.to_s }, "failed" => ->(row) { row.count } }.freeze
    TABLE_SORT_COLUMNS = { "table" => ->(row) { row.table.to_s }, "size" => ->(row) { row.size_bytes },
                           "rows" => ->(row) { row.est_rows } }.freeze

    def show
      @system_health = SystemHealth.new
      @backlog = sorted_rows(@system_health.ready_backlog, columns: BACKLOG_SORT_COLUMNS, param: :backlog_sort)
      @failed = sorted_rows(@system_health.failed_breakdown, columns: FAILED_SORT_COLUMNS, param: :failed_sort)
      @tables = sorted_rows(@system_health.growing_tables, columns: TABLE_SORT_COLUMNS, param: :tables_sort)
    end
  end
end
