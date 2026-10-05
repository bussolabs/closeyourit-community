# frozen_string_literal: true

module Ui
  class PageHeaderComponent
    # One page tab on the header's bottom row (DESIGN.md T2, B14). `icon:` is a bare Lucide name
    # ("lock", "github"). The header reads `label`, `href`, `icon` and
    # `active?` to draw the entries of its More menu. `count:` adds a badge when positive
    # (the unread notifications of each nature), tagged `count_test_id:`. `data:` reaches the link,
    # for tabs that switch a panel on the page instead of leaving it. A block adds a trailing mark of
    # the tab's own (a live counter, a version, a dot).
    class TabComponent < BaseComponent
      CLASSES = {
        true => "h-11 px-1 inline-flex items-center gap-1.5 whitespace-nowrap border-b-2 border-indigo-600 dark:border-indigo-400 text-[13px] font-semibold text-zinc-900 dark:text-zinc-100",
        false => "h-11 px-1 inline-flex items-center gap-1.5 whitespace-nowrap border-b-2 border-transparent text-[13px] font-medium text-gray-500 dark:text-zinc-400 hover:text-zinc-900 dark:hover:text-zinc-100"
      }.freeze
      ICON_CLASSES = { true => "text-[11px] text-indigo-500 dark:text-indigo-400", false => "text-[11px] text-gray-400 dark:text-zinc-500" }.freeze
      COUNT_BASE = "inline-flex items-center justify-center min-w-[18px] h-[18px] px-1 rounded-full font-mono text-[10px] font-semibold"
      # Amber is for a count that waits on a person; indigo for everything else.
      COUNT_COLORS = {
        indigo: "bg-indigo-100 dark:bg-indigo-500/25 text-indigo-700 dark:text-indigo-300",
        amber: "bg-amber-100 dark:bg-amber-500/25 text-amber-700 dark:text-amber-300"
      }.freeze

      attr_reader :label, :href, :icon, :test_id

      def initialize(label:, href:, active: false, icon: nil, count: nil, count_color: :indigo, count_test_id: nil, count_title: nil,
                     test_id: nil, data: {})
        @label = label
        @href = href
        @active = active
        @icon = icon
        @count = count
        @count_color = count_color.to_sym
        @count_test_id = count_test_id
        @count_title = count_title
        @test_id = test_id
        @data = data
      end

      def active? = @active

      def call
        link_to(href, class: CLASSES[active?], "aria-current": (active? ? "page" : nil), data: { test: test_id }.compact.merge(@data)) do
          safe_join([ (render(Ui::IconComponent.new(name: icon, class: ICON_CLASSES[active?])) if icon), label, count_badge, content.presence ].compact)
        end
      end

      private

      def count_badge
        return unless @count.to_i.positive?

        tag.span(@count, class: "#{COUNT_BASE} #{COUNT_COLORS.fetch(@count_color)}", title: @count_title, data: { test: @count_test_id }.compact)
      end
    end
  end
end
