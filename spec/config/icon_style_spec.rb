# frozen_string_literal: true

require "rails_helper"

# DESIGN.md A31 — every icon is a Lucide outline glyph drawn by Ui::IconComponent (CYRA-926).
RSpec.describe "Icon style" do
  let(:sources) { Rails.root.glob("app/**/*.{rb,erb,js}") }

  it "no file uses a Font Awesome class" do
    offenders = sources.select { |path| path.read.match?(/\bfa-[a-z]/) }

    expect(offenders.map { |path| path.relative_path_from(Rails.root).to_s }).to be_empty
  end

  it "no layout loads Font Awesome" do
    offenders = Rails.root.glob("app/views/layouts/*.erb").select { |path| path.read.include?("font-awesome") }

    expect(offenders.map { |path| path.basename.to_s }).to be_empty
  end

  it "every icon name written in code is one Lucide can draw" do
    unknown = sources.flat_map do |path|
      path.read.scan(/IconComponent\.new\(name: "([a-z0-9-]+)"/).flatten
          .reject { |name| LucideRails::IconProvider.memory.key?(name) }
          .map { |name| "#{path.relative_path_from(Rails.root)}: #{name}" }
    end

    expect(unknown).to be_empty
  end
end
