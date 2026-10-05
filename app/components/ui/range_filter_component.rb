# frozen_string_literal: true

module Ui
  # CYRA-985 — a period in one control: the trigger shows it, the panel holds the presets, the two
  # custom dates and Apply. The value lives in a hidden field marked `data-filter-bar-value`, which
  # the filter bar reads and clears like the select of any other chip.
  #
  # options: array of `[label, value]`; the first is the default, `custom` is the value of the dates.
  class RangeFilterComponent < BaseComponent
    INPUT_FORMAT = "%Y-%m-%dT%H:%M"
    FIELD = "w-full h-[34px] px-2.5 rounded-md border border-stone-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 " \
            "font-mono text-[13px] text-zinc-900 dark:text-zinc-100 dark:[color-scheme:dark] focus:outline-none " \
            "focus:border-indigo-600 dark:focus:border-indigo-400 focus-visible:ring-2 " \
            "focus-visible:ring-indigo-500 dark:focus-visible:ring-indigo-400"

    def initialize(name:, label:, options:, custom:, test_id:, bounds_test_prefix:, selected: nil, from: nil, to: nil)
      @name = name
      @label = label
      @options = options
      @custom = custom.to_s
      @test_id = test_id
      @bounds_test_prefix = bounds_test_prefix
      @selected = selected.to_s
      @from = from
      @to = to
    end

    private

    def presets = @options.reject { |_, value| value.to_s == @custom }

    def selected?(value) = value.to_s == @selected

    def custom? = @selected == @custom

    def bounds = [ [ "from", @from ], [ "to", @to ] ]

    def input_value(time) = time&.strftime(INPUT_FORMAT)

    def summary
      return period if custom? && (@from || @to)

      (@options.find { |_, value| selected?(value) } || @options.first).first
    end

    # Same day: the date once ("2 Oct, 20:30 → 21:00"). One bound only: the open side is named.
    def period
      return t("shared.time_range.since", time: moment(@from)) unless @to
      return t("shared.time_range.until", time: moment(@to)) unless @from
      return "#{day(@from)}, #{clock(@from)} → #{clock(@to)}" if @from.to_date == @to.to_date

      "#{moment(@from)} → #{moment(@to)}"
    end

    def moment(time) = "#{day(time)} #{clock(time)}"

    def day(time) = l(time.to_date, format: "%-d %b")

    def clock(time) = time.strftime("%H:%M")
  end
end
