# frozen_string_literal: true

module Ui
  # The only way to draw an icon (DESIGN.md A31): a Lucide outline glyph as inline SVG, 1em wide with a
  # currentColor stroke, so `text-[11px] text-gray-400` size and color it like a font glyph. Hidden from
  # screen readers unless it has a `label:`. An unknown name raises from the gem: a bug to see early. CYRA-926
  class IconComponent < BaseComponent
    include LucideRails::RailsHelper

    BASE = "inline-block shrink-0 align-[-0.125em]"

    def initialize(name:, label: nil, test_id: nil, **options)
      @name = name.to_s
      @label = label
      @test_id = test_id
      @options = options
    end

    # A labelled icon carries a <title>: an SVG shows no tooltip for a title attribute.
    def call
      return lucide_icon(@name, **html_options) if @label.blank?

      paths = LucideRails::IconProvider.icon(@name).html_safe # rubocop:disable Rails/OutputSafety -- the gem's own SVG paths
      content_tag(:svg, safe_join([ tag.title(@label), paths ]), LucideRails.default_options.merge(html_options))
    end

    private

    def html_options
      options = merge_options(base_class: BASE, test_id: @test_id, options: @options)
      options[:data] = (options[:data] || {}).merge(icon: @name)
      options.merge(width: "1em", height: "1em", **accessibility)
    end

    # The gem's defaults hide every icon; a nil value drops that attribute from a labelled one.
    def accessibility
      @label.present? ? { role: "img", "aria-label": @label, "aria-hidden": nil } : { "aria-hidden": "true" }
    end
  end
end
