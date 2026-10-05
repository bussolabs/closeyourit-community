# frozen_string_literal: true

module Ui
  class TableComponent < BaseComponent
    # CYRA-924 — the detail under a row (DESIGN.md C58): one cell across every column, hidden until
    # the row opens it. Pass `colspan: table.column_count`.
    class DetailRowComponent < BaseComponent
      def initialize(colspan:, hidden: false, test_id: nil, **options)
        @colspan = colspan
        @hidden = hidden
        @test_id = test_id
        @options = options
      end

      def call
        opts = merge_options(base_class: "ui-table-detail", test_id: @test_id, options: @options)
        opts[:hidden] = true if @hidden
        tag.tr(**opts) { tag.td(content, colspan: @colspan) }
      end
    end
  end
end
