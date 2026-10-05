# frozen_string_literal: true

module Ui
  class TableComponent < BaseComponent
    # CYRA-924 — the row that opens and closes a group (DESIGN.md C57, C72): name, Mono count and a
    # chevron, across every column. Rows join it with `RowComponent.new(group: key)`; the table
    # needs `grouped: true` for the toggle to work. Without JavaScript every group stays open.
    # `href:` adds a link to the group's own page next to the toggle; `with_actions` puts the group's
    # own commands (a button, a row menu) at the right end of the row.
    class GroupRowComponent < BaseComponent
      renders_one :actions

      def initialize(key:, label:, colspan:, count: nil, collapsed: false, href: nil, link_label: nil,
                     link_test_id: nil, test_id: nil, toggle_test_id: nil)
        @href = href
        @link_label = link_label
        @link_test_id = link_test_id
        @key = key
        @label = label
        @colspan = colspan
        @count = count
        @collapsed = collapsed
        @test_id = test_id
        @toggle_test_id = toggle_test_id || (test_id && "#{test_id}-toggle")
      end

      def call
        tag.tr(class: "ui-table-group", data: { test: @test_id }.compact) do
          tag.td(colspan: @colspan) do
            toggle = tag.button(type: "button", class: button_class, "aria-expanded": (!@collapsed).to_s,
                                data: { action: "ui--row-group#toggle", "ui--row-group-key-param": @key,
                                        test: @toggle_test_id }.compact) do
              safe_join([ chevron, tag.span(@label), count ].compact)
            end
            row = [ toggle, group_link, (tag.span(actions, class: "ml-auto flex items-center gap-1.5") if actions?) ].compact
            actions? ? tag.div(safe_join(row), class: "flex items-center gap-2") : safe_join(row)
          end
        end
      end

      private

      def group_link
        return unless @href

        link_to(@href, class: "ml-2 text-[11px] text-gray-400 dark:text-zinc-500 hover:text-indigo-600 dark:hover:text-indigo-400", "aria-label": @link_label,
                data: { test: @link_test_id }.compact) do
          render(Ui::IconComponent.new(name: "arrow-up-right-from-square"))
        end
      end

      def button_class
        "inline-flex items-center gap-2 text-[12.5px] font-semibold text-stone-700 dark:text-zinc-300 hover:text-zinc-900 dark:hover:text-zinc-100 " \
          "focus-visible:outline-2 focus-visible:outline-indigo-600 dark:focus-visible:outline-indigo-400"
      end

      def chevron
        render(Ui::IconComponent.new(name: "chevron-down",
                                     class: [ "text-[10px] text-gray-400 dark:text-zinc-500 motion-safe:transition-transform",
                                              ("-rotate-90" if @collapsed) ].compact.join(" "),
                                     data: { "row-group-chevron": true }))
      end

      def count
        tag.span(@count, class: "font-mono text-[11px] font-medium text-gray-500 dark:text-zinc-400") unless @count.nil?
      end
    end
  end
end
