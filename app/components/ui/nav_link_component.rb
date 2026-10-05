# frozen_string_literal: true

module Ui
  # One row of the member sidebar (CYRA-903): pinned entries, simple entries, group names, leaves and
  # the account links of the mobile drawer. Was the same markup copied three times, with its colours
  # passed down from the layout as lambdas. Trailing content (a badge, the current-area mark) goes in
  # the block. In compact mode the label stays for screen readers only.
  class NavLinkComponent < BaseComponent
    SIZES = {
      top: "flex items-center gap-2.5 px-3 h-8 rounded-md text-[13px] font-medium md:group-data-[compact]/sidebar:justify-center md:group-data-[compact]/sidebar:px-0",
      # Sidebar footer (Guides): the small text of the version and the compact toggle next to it.
      footer: "flex items-center gap-2.5 px-3 h-8 rounded-md text-[12px] font-medium md:group-data-[compact]/sidebar:justify-center md:group-data-[compact]/sidebar:px-0",
      leaf: "flex items-center px-3 py-1.5 pl-10 rounded-md text-[12.5px]",
      # A leaf inside the compact-mode flyout (CYRA-909): no indent, the panel already sits beside the group.
      flyout: "flex items-center px-3 py-1.5 rounded-md text-[12.5px]",
      account: "flex items-center gap-2.5 px-3 h-8 rounded-md text-[12px] font-medium"
    }.freeze

    ICON_SIZES = { top: "text-[14px]", footer: "text-[13px]", account: "text-[13px]" }.freeze

    LINK_ACTIVE = "bg-indigo-50 dark:bg-indigo-500/15 text-indigo-700 dark:text-indigo-300"
    LINK_IDLE = "text-gray-600 dark:text-zinc-400 hover:text-zinc-900 dark:hover:text-zinc-100 hover:bg-stone-100 dark:hover:bg-zinc-800"
    ICON_ACTIVE = "text-indigo-500 dark:text-indigo-400"
    ICON_IDLE = "text-gray-400 dark:text-zinc-500"

    COMPACT_HIDDEN = "md:group-data-[compact]/sidebar:hidden"
    COMPACT_SR_ONLY = "md:group-data-[compact]/sidebar:sr-only"
    # CYRA-909 — in compact mode a count shrinks to a dot on the icon's corner; its aria-label stays.
    COMPACT_DOT = "md:group-data-[compact]/sidebar:absolute md:group-data-[compact]/sidebar:top-1 " \
                  "md:group-data-[compact]/sidebar:right-3 md:group-data-[compact]/sidebar:**:size-2 " \
                  "md:group-data-[compact]/sidebar:**:min-w-0 md:group-data-[compact]/sidebar:**:p-0 " \
                  "md:group-data-[compact]/sidebar:**:ms-0 md:group-data-[compact]/sidebar:**:text-[0px]"

    # `current` is the aria-current value when active: "page" for a destination, "true" for a group
    # name whose area holds the open page. `dot` keeps the trailing count visible in compact mode, as a dot.
    # `detail` is a second, muted line under the label (the Coworkers sidebar shows each Puck's last answer).
    def initialize(label:, path:, icon: nil, active: false, current: "page", size: :top, test_id: nil,
                   icon_class: nil, dot: false, detail: nil, **options)
      @label = label
      @detail = detail
      @path = path
      @icon = icon
      @active = active
      @current = current
      @size = SIZES.key?(size) ? size : :top
      @test_id = test_id
      @icon_class = icon_class
      @dot = dot
      @options = options
    end

    def call
      link_to(@path, **html_options) do
        safe_join([ icon_tag, label_tag, trailing_tag ].compact)
      end
    end

    private

    def compact? = %i[top footer].include?(@size)

    def html_options
      options = @options.merge(aria: { current: (@current if @active) }.compact)
      options = options.merge(data: (options[:data] || {}).merge(nav_label: @label)) if compact?
      merge_options(base_class: "#{SIZES[@size]}#{" relative" if @dot} #{@active ? LINK_ACTIVE : LINK_IDLE}", test_id: @test_id,
                    options: options)
    end

    def icon_tag
      return unless @icon

      colour = @icon_class || (@active ? ICON_ACTIVE : ICON_IDLE)
      render(Ui::IconComponent.new(name: @icon,
                                   class: "w-[1.25em] shrink-0 #{ICON_SIZES.fetch(@size, ICON_SIZES[:top])} #{colour}"))
    end

    def label_tag
      classes = [ "truncate flex-1", (COMPACT_SR_ONLY if compact?) ].compact.join(" ")
      return tag.span(@label, class: classes) unless @detail

      tag.span(class: "#{classes} flex flex-col min-w-0") do
        safe_join([ tag.span(@label, class: "truncate"),
                    tag.span(@detail, class: "truncate text-[11.5px] font-normal text-gray-500 dark:text-zinc-400", data: { test: "nav-detail" }) ])
      end
    end

    def trailing_tag
      return unless content?

      compact? ? tag.span(content, class: "inline-flex items-center #{@dot ? COMPACT_DOT : COMPACT_HIDDEN}") : content
    end
  end
end
