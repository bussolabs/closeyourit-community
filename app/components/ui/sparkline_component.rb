# frozen_string_literal: true

module Ui
  # A trend in a table cell: one line over the points, the last one marked. Decorative next to its
  # number, so it is hidden from screen readers; `label:` goes in a <title> for the pointer.
  class SparklineComponent < BaseComponent
    WIDTH = 96
    HEIGHT = 18
    TONES = { red: "text-red-500 dark:text-red-400", gray: "text-stone-300 dark:text-zinc-600" }.freeze

    def initialize(points:, tone: :gray, label: nil)
      @points = Array(points).map(&:to_i)
      @tone = tone
      @label = label
    end

    def render? = @points.size > 1

    def call
      tag.svg(viewBox: "0 0 #{WIDTH} #{HEIGHT}", class: "block w-24 h-[18px] #{TONES.fetch(@tone)}",
              "aria-hidden": "true", data: { test: "sparkline" }) do
        safe_join([ (tag.title(@label) if @label),
                    tag.polyline(points: coordinates.map { |x, y| "#{x},#{y}" }.join(" "), fill: "none",
                                 stroke: "currentColor", "stroke-width": "1.4", "stroke-linejoin": "round"),
                    tag.circle(cx: coordinates.last[0], cy: coordinates.last[1], r: "2", fill: "currentColor") ].compact)
      end
    end

    private

    def coordinates
      @coordinates ||= begin
        top = [ @points.max, 1 ].max
        step = WIDTH.to_f / (@points.size - 1)
        @points.each_with_index.map { |value, index| [ (index * step).round(1), (HEIGHT - 2 - (value.to_f / top * (HEIGHT - 4))).round(1) ] }
      end
    end
  end
end
