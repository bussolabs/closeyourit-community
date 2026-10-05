# frozen_string_literal: true

module Ui
  # The one shell every dialog opens in (F24), the same as the member modal that hosts each New: the
  # dark ground, a page header panel with the title and the actions, the content in its own panel.
  # It draws no behaviour: the caller keeps its own wiring (Stimulus target, actions, id) on the
  # <dialog>. With `form:` the header and the panel sit in one form, so a Save in the header submits it.
  class ModalComponent < BaseComponent
    renders_one :actions

    SIZES = {
      sm: "w-[min(28rem,calc(100vw-2rem))]",
      md: "w-[min(40rem,calc(100vw-2rem))]",
      lg: "w-[min(56rem,calc(100vw-2rem))]"
    }.freeze
    SHELL = "m-auto max-h-[calc(100dvh-2rem)] overflow-y-auto rounded-xl border border-stone-200 dark:border-zinc-800 " \
            "bg-stone-100 dark:bg-zinc-950 text-left text-zinc-900 dark:text-zinc-100 p-0 " \
            "backdrop:bg-zinc-900/40 backdrop:backdrop-blur-sm"
    PANEL = "rounded-lg border border-stone-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 overflow-hidden"

    def initialize(title:, subtitle: nil, size: :md, padded: true, form: nil, test_id: nil, **options)
      raise ArgumentError, "unknown size: #{size}" unless SIZES.key?(size)

      @title = title
      @subtitle = subtitle
      @size = size
      @padded = padded
      @form = form
      @test_id = test_id
      @options = options
    end

    private

    def dialog_options = merge_options(base_class: "#{SHELL} #{SIZES.fetch(@size)}", test_id: @test_id, options: @options)

    def panel_class = [ PANEL, ("p-4 text-[12.5px] leading-relaxed text-gray-600 dark:text-zinc-400" if @padded) ].compact.join(" ")

    def panel_test_id = @test_id && "#{@test_id}-panel"

    # Never the page-header-* hooks: they belong to the one page header (F24).
    def header_test_id = "#{@test_id || "modal"}-header"
  end
end
