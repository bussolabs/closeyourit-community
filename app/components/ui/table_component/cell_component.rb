# frozen_string_literal: true

module Ui
  class TableComponent < BaseComponent
    # CYRA-924 — one table cell. Padding comes from the table's density (C53), `label:` names the
    # column on the mobile card (C69, C73), `header:` makes the row's name cell, `visible: false`
    # hides a column that says nothing here (C76). Exceptional states are pills, never a tint (C67).
    class CellComponent < BaseComponent
      def initialize(label: nil, header: false, align: :left, mono: false, actions: false,
                     visible: true, test_id: nil, **options)
        @label = label
        @header = header
        @align = actions ? :right : align
        @mono = mono
        @actions = actions
        @visible = visible
        @test_id = test_id
        @options = options
      end

      def render? = @visible

      def call
        opts = merge_options(base_class: cell_class, test_id: @test_id, options: @options)
        opts[:data] = (opts[:data] || {}).merge(label: @label) if @label
        if @header
          tag.th(content, scope: "row", **opts)
        else
          tag.td(content, **opts)
        end
      end

      private

      def cell_class
        [ "ui-table-cell", ("ui-table-cell--title" if @header), ("ui-table-cell--actions whitespace-nowrap" if @actions), ("text-right" if @align == :right), ("font-mono tabular-nums" if @mono) ].compact.join(" ")
      end
    end
  end
end
