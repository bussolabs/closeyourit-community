# frozen_string_literal: true

module Ui
  # Page/form header, drawn as a panel (DESIGN.md T1, T2; mockup docs/mockups/secrets-panels.html).
  # Top: breadcrumb, then the title block (h1, optional info icon, one-line `subtitle:`) with the
  # `actions` slot beside it, wrapping below on narrow screens; then `meta`.
  # Bottom row, drawn only when there is something to put in it: the page `tabs` (the least used in
  # `more_tabs`, behind a More menu, B14) and the `counts` line at its right end, also without tabs.
  # `breadcrumb:` (array of { label:, href: }, rendered by Ui::BreadcrumbComponent) is shown only when
  # it leads somewhere: a trail that is empty or only names the current page repeats the h1 (CYRA-883).
  # `back_href`/`back_label` remain for pages not yet on the trail; the breadcrumb wins.
  #
  # `title_tooltip:` renders an info bubble beside the title (Valhalla); member pages say what they
  # contain in the `subtitle:` instead, and carry no tip bubble or guide link (CYRA-883).
  class PageHeaderComponent < BaseComponent
    renders_one :actions
    renders_one :counts
    renders_one :meta
    # An object's page (B11): the color square before the title, its Mono code and badges after it.
    renders_one :mark
    renders_one :badges
    renders_many :tabs, TabComponent
    renders_many :more_tabs, TabComponent

    PANEL = "group/header rounded-lg border border-stone-200 dark:border-zinc-800 bg-white dark:bg-zinc-900"
    # Stuck 1px up, so its top border sits under the frame's (T1).
    STICKY = "sticky -top-px z-20"
    # In the member modal the header stays at the top while the form scrolls: save from anywhere.
    MODAL_STICKY = "sticky top-0 z-20"

    TOP_CLASSES = {
      true => "px-4 pt-4 group-data-[collapsed]/header:pt-2.5",
      false => "p-4 group-data-[collapsed]/header:py-2.5"
    }.freeze

    HEADINGS = { h1: :h1, h2: :h2 }.freeze

    def initialize(title:, subtitle: nil, title_tooltip: nil, breadcrumb: nil,
                   root_href: nil, root_label: nil, back_href: nil, back_label: nil, counts_test_id: nil,
                   tabs_test_id: nil, test_id: nil, collapsible: true, heading: :h1, **options)
      @title = title
      # h1 for the page; a dialog built on this header titles itself with an h2 (one h1 per page).
      @heading = HEADINGS.fetch(heading)
      @collapsible = collapsible
      @subtitle = subtitle
      @title_tooltip = title_tooltip
      @breadcrumb = breadcrumb
      @root_href = root_href
      @root_label = root_label
      @back_href = back_href
      @back_label = back_label
      @counts_test_id = counts_test_id
      @tabs_test_id = tabs_test_id
      @test_id = test_id
      @options = options
    end

    private

    def subtitle_test_id
      @test_id ? "#{@test_id}-subtitle" : "page-header-subtitle"
    end

    # Inner test ids follow `test_id` ("project" -> "project-actions"), like the subtitle.
    def part_test_id(part)
      @test_id ? "#{@test_id}-#{part}" : "page-header-#{part}"
    end

    def back_test_id = part_test_id("back")

    def title_help_test_id
      @test_id ? "#{@test_id}-title-help" : "page-header-title-help"
    end

    def show_breadcrumb?
      return false if @breadcrumb.nil? || @breadcrumb.empty? || in_modal?
      return true unless @breadcrumb.size == 1 && @breadcrumb.first[:label].to_s == @title.to_s

      area_level?
    end

    # B22 — a lone crumb that repeats the title still leads somewhere when the trail adds an area level:
    # not on a pinned page, nor in an area named like the page (Projects).
    def area_level?
      return false unless helpers.respond_to?(:current_group)

      group = helpers.current_group
      group.present? && !group.pinned? && group.label != @title.to_s
    end

    def top_block?
      show_breadcrumb? || (@breadcrumb.nil? && @back_href.present?)
    end

    def any_tabs?
      tabs? || more_tabs?
    end

    def bottom_row?
      any_tabs? || counts?
    end

    def active_more_tab
      more_tabs.find(&:active?)
    end

    def container_options
      base = "#{PANEL} #{STICKY}" if collapsible?
      base ||= in_modal? ? "#{PANEL} #{MODAL_STICKY}" : PANEL
      merge_options(base_class: base, test_id: @test_id, options: @options).tap do |opts|
        opts[:data] = (opts[:data] || {}).merge(collapse_data) if collapsible?
      end
    end

    # B25 — member pages only: the area exposes the person's saved choice.
    def collapsible?
      @collapsible && helpers.respond_to?(:page_header_compact?) && !in_modal?
    end

    # CYRA-933 — inside the member modal the page is already behind it: no trail, nothing to collapse.
    def in_modal?
      helpers.respond_to?(:modal_form_request?) && helpers.modal_form_request?
    end

    def pinned?
      collapsible? && helpers.page_header_compact?
    end

    def collapse_data
      { controller: "ui--page-header", ui__page_header_url_value: helpers.member_page_header_preference_path,
        pinned: (pinned? ? "" : nil), collapsed: (pinned? ? "" : nil) }.compact
    end

    def collapse_toggle
      return unless collapsible?

      render Ui::ButtonComponent.new(
        label: t(pinned? ? "ui.page_header.expand" : "ui.page_header.collapse"),
        variant: :secondary_muted, size: :sm, icon: "chevrons-up", icon_only: true, test_id: part_test_id("collapse"),
        class: "[&_svg]:transition-transform group-data-[collapsed]/header:[&_svg]:rotate-180",
        aria: { expanded: (!pinned?).to_s },
        data: { ui__page_header_target: "toggle", action: "ui--page-header#toggle",
                collapse_label: t("ui.page_header.collapse"), expand_label: t("ui.page_header.expand") }
      )
    end

    def top_class
      TOP_CLASSES[bottom_row?]
    end

    # Without tabs the counts still sit at the right end of the row (T2).
    def counts_options
      base = "flex flex-wrap items-center gap-x-1.5 gap-y-1 py-2.5 text-[12px] text-gray-500 dark:text-zinc-400"
      { class: any_tabs? ? base : "#{base} ml-auto" }.tap do |o|
        o[:data] = { test: @counts_test_id } if @counts_test_id
      end
    end

    def more_trigger_class
      "#{TabComponent::CLASSES[active_more_tab.present?]} list-none cursor-pointer"
    end

    # The "More" trigger names the active hidden tab, with its icon, or just says "More".
    def more_trigger_label
      tab = active_more_tab
      return t("ui.page_header.more") unless tab

      icon = render(Ui::IconComponent.new(name: tab.icon, class: "text-[11px] text-indigo-500 dark:text-indigo-400")) if tab.icon
      safe_join([ icon, tab.label ].compact)
    end

    def more_item_label(tab)
      color = tab.active? ? "text-indigo-500 dark:text-indigo-400" : "text-gray-400 dark:text-zinc-500"
      icon = render(Ui::IconComponent.new(name: tab.icon, class: "w-4 text-center text-[11px] #{color}")) if tab.icon
      safe_join([ icon, tab.label ].compact)
    end

    def more_item_class(tab)
      "#{Ui::RowMenuComponent.item_class(:default)} #{'font-semibold text-indigo-700 dark:text-indigo-300' if tab.active?}"
    end
  end
end
