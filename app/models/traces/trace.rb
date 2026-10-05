# frozen_string_literal: true

module Traces
  class Trace < ApplicationRecord
    self.table_name = "traces"
    belongs_to :project, class_name: "Projects::Project"
    has_many :spans, class_name: "Traces::Span", foreign_key: :trace_record_id, inverse_of: :trace_record, dependent: :delete_all

    scope :with_topology, -> {
      select("traces.*", <<~SQL.squish, <<~SQL.squish)
        EXISTS (SELECT 1 FROM traces_spans roots
          WHERE roots.trace_record_id = traces.id AND roots.parent_span_id IS NULL) AS observed_root_present
      SQL
        (SELECT COUNT(DISTINCT children.parent_span_id) FROM traces_spans children
          WHERE children.trace_record_id = traces.id AND children.parent_span_id IS NOT NULL
            AND NOT EXISTS (SELECT 1 FROM traces_spans parents
              WHERE parents.trace_record_id = children.trace_record_id
                AND parents.span_id = children.parent_span_id)) AS observed_missing_parent_count
      SQL
    }

    def topology
      observed = has_attribute?(:observed_root_present) ? self : self.class.with_topology.find(id)
      missing = observed[:observed_missing_parent_count].to_i
      root = observed[:observed_root_present]
      { root_present: root, missing_parent_count: missing,
        completeness: !root || missing.positive? || expired_spans_count.positive? ? "incomplete" : "unknown" }
    end
  end
end
