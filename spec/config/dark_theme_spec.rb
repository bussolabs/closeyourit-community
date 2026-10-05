# frozen_string_literal: true

require "rails_helper"
require_relative "../support/ui_dark_palette"

# DESIGN.md A32: the rewritten components have a dark look, the others do not have one yet.
RSpec.describe "Dark theme of the rewritten components" do
  it "keeps descendant selectors intact when checking light and dark variants" do
    expect("[&_code]:bg-stone-100".scan(UiDarkPalette::LIGHT_CLASS))
      .to eq([ [ "[&_code]:", "bg-stone-100" ] ])
    expect("dark:[&_a]:text-indigo-500".scan(UiDarkPalette::LIGHT_CLASS))
      .to eq([ [ "dark:[&_a]:", "text-indigo-500" ] ])
  end

  it "covers the files of every rewritten component" do
    UiDarkPalette::COMPONENTS.each do |name|
      expect(UiDarkPalette.files.grep(%r{/#{name}_component[./]})).not_to be_empty, "#{name} has no files"
    end
  end

  it "gives every mapped light class its dark counterpart on the same line" do
    missing = UiDarkPalette.files.flat_map do |path|
      lines = File.readlines(path)
      lines.each_with_index.flat_map do |line, index|
        next [] if UiDarkPalette.comment?(line)

        line.scan(UiDarkPalette::LIGHT_CLASS).filter_map do |variants, light|
          next if variants.start_with?("dark:")

          dark = UiDarkPalette.dark_class(variants, light)
          # classList.toggle takes one class, so a Stimulus controller toggles the dark one on the next line.
          # A surface may pick a stronger dark than the map (a floating notice must be opaque): any dark
          # class for the same property and variants counts.
          same_property = "dark:#{variants}#{light[/\A[a-z]+-/]}"
          paired = line.include?(same_property) || (path.end_with?(".js") && lines[index + 1].to_s.include?(dark))
          "#{path.delete_prefix("#{Rails.root}/")}:#{index + 1} #{variants}#{light} needs #{dark}" unless paired
        end
      end
    end

    expect(missing).to be_empty, missing.join("\n")
  end

  # `dark:bg-zinc-900` beats `md:bg-transparent`, so an unmapped breakpoint colour needs its own `dark:md:` twin.
  it "keeps breakpoint colours in force in the dark look" do
    breakpoint = /(?<![\w:-])((?:sm|md|lg|xl|2xl):)((bg|text|border)-(?:transparent|white|black|[a-z]+-\d{2,3}(?:\/\d+)?))(?![\w\/-])/
    missing = UiDarkPalette.files.reject { it.end_with?(".js") }.flat_map do |path|
      File.readlines(path).each_with_index.flat_map do |line, index|
        next [] if UiDarkPalette.comment?(line)

        line.scan(breakpoint).filter_map do |variant, klass, property|
          next if UiDarkPalette::MAP.key?(klass) || !line.match?(/(?<![\w:-])dark:#{property}-/)

          "#{path.delete_prefix("#{Rails.root}/")}:#{index + 1} needs dark:#{variant}#{klass}" unless line.include?("dark:#{variant}#{klass}")
        end
      end
    end

    expect(missing).to be_empty, missing.join("\n")
  end

  # Stacked avatars overlap: a see-through fill shows the one underneath.
  it "gives overlapping avatars an opaque dark fill" do
    offenders = UiDarkPalette.files.reject { it.end_with?(".js") }.flat_map do |path|
      File.readlines(path).each_with_index.filter_map do |line, index|
        "#{path.delete_prefix("#{Rails.root}/")}:#{index + 1}" if line.include?("ring-2 ring-white") && line.match?(%r{dark:bg-[a-z]+-\d+/\d+})
      end
    end

    expect(offenders).to be_empty, offenders.join("\n")
  end

  it "keeps dark classes out of the components and views not rewritten yet" do
    allowed = (UiDarkPalette.files + [ Rails.root.join("app/views/layouts/component_preview.html.erb").to_s ]).to_set
    sources = Dir[Rails.root.join("app/views/**/*.erb")] + Dir[Rails.root.join("app/components/**/*.{erb,rb}")]
    offenders = sources.reject { allowed.include?(it) }.select { File.read(it).match?(/(?<![\w-])dark:[a-z]/) }

    expect(offenders.map { it.delete_prefix("#{Rails.root}/") }).to be_empty
  end

  it "turns dark on only through the dark class, never the system setting" do
    css = Rails.root.join("app/assets/tailwind/application.css").read

    expect(css).to include("@custom-variant dark (&:where(.dark, .dark *));")
  end
end
