# frozen_string_literal: true

module Ui
  class TableComponent < BaseComponent
    # CYRA-924 — one table row (DESIGN.md C52–C58, C70, C74, C79). With `href:` the whole row opens
    # the detail and a real chevron link closes it, so keyboard and "open in a new tab" still work.
    # Below 768px the stacked table restyles this same row as a card (C73). `frame:` sends the
    # chevron link to that Turbo frame ("_top" for a row inside a frame). `select:` puts the row's
    # selection box first (C56): a Hash for the checkbox, `:none` for an empty cell on a row that
    # cannot be selected.
    class RowComponent < BaseComponent
      def initialize(href: nil, link_label: nil, frame: nil, select: nil, highlighted: false, selected: false,
                     faded: false, group: nil, hidden: false, test_id: nil, **options)
        @href = href
        @link_label = link_label
        @frame = frame
        @select = select
        @highlighted = highlighted
        @selected = selected
        @faded = faded
        @group = group
        @hidden = hidden
        @test_id = test_id
        @options = options
      end

      def call
        tag.tr(**row_options) do
          safe_join([ select_cell, content, chevron_cell ].compact)
        end
      end

      private

      def select_cell
        return unless @select
        return tag.td(class: "ui-table-select") if @select == :none

        tag.td(class: "ui-table-select") do
          tag.input(type: "checkbox", name: @select[:name], value: @select[:value],
                    "aria-label": @select[:label] || t("shared.bulk_triage.select_row"),
                    class: "h-3.5 w-3.5 rounded border-stone-300 dark:border-zinc-700 text-indigo-600 dark:text-indigo-400 focus:ring-indigo-500 dark:focus:ring-indigo-400",
                    data: { "ui--bulk-select-target": "checkbox", action: "change->ui--bulk-select#update",
                            test: @select[:test_id] }.compact.merge(@select.fetch(:data, {})))
        end
      end

      def chevron_cell
        return unless @href

        tag.td(class: "ui-table-chevron", data: { "ui--row-link-skip": true }) do
          link_to(@href, class: "text-gray-400 dark:text-zinc-500 hover:text-zinc-900 dark:hover:text-zinc-100", "aria-label": @link_label,
                  data: { turbo_frame: @frame }.compact) do
            render(Ui::IconComponent.new(name: "chevron-right", class: "text-[10px]"))
          end
        end
      end

      def row_options
        classes = [ "ui-table-row", ("ui-table-row--faded" if @faded), ("ui-table-row--link" if @href) ].compact.join(" ")
        opts = merge_options(base_class: classes, test_id: @test_id, options: @options)
        opts[:data] = (opts[:data] || {}).merge(link_data).merge(group_data)
        opts[:"aria-current"] = "true" if @highlighted
        opts[:"aria-selected"] = "true" if @selected
        opts[:hidden] = true if @hidden
        opts
      end

      def link_data
        return {} unless @href

        controller = [ @options.dig(:data, :controller), "ui--row-link" ].compact.join(" ")
        action = [ @options.dig(:data, :action), "click->ui--row-link#open" ].compact.join(" ")
        { controller: controller, action: action, "ui--row-link-url-value": @href }
      end

      def group_data
        return {} unless @group

        { "ui--row-group-target": "row", "row-group-key": @group }
      end
    end
  end
end
