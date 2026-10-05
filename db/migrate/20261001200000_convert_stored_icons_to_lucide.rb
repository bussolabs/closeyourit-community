# frozen_string_literal: true

# CYRA-926 — icons are Lucide now: the Font Awesome names already picked for projects, groups and
# uptime groups become their Lucide names. The map is frozen here, not read from Ui::Icons, so the
# migration keeps meaning what it meant when it ran. Names equal in both sets are left alone.
class ConvertStoredIconsToLucide < ActiveRecord::Migration[8.1]
  TABLES = %w[projects projects_groups uptime_groups].freeze

  FONT_AWESOME_TO_LUCIDE = {
    "gauge-high" => "gauge", "mobile-screen" => "smartphone", "flask-vial" => "flask-conical",
    "shield-halved" => "shield-half", "cube" => "box", "layer-group" => "layers", "gear" => "settings",
    "fire" => "flame", "flag-checkered" => "flag", "diagram-project" => "workflow", "sitemap" => "network",
    "cubes" => "boxes", "robot" => "bot", "puzzle-piece" => "puzzle", "tower-broadcast" => "radio-tower",
    "wand-magic-sparkles" => "wand-sparkles", "box" => "package"
  }.freeze

  def up
    rename_icons(FONT_AWESOME_TO_LUCIDE)
  end

  def down
    rename_icons(FONT_AWESOME_TO_LUCIDE.invert)
  end

  private

  # One CASE per table, so "box" -> "package" and "cube" -> "box" cannot chain into each other.
  def rename_icons(map)
    cases = map.map { |from, to| "WHEN #{quote(from)} THEN #{quote(to)}" }.join(" ")
    keys = map.keys.map { |name| quote(name) }.join(", ")
    TABLES.each do |table|
      execute "UPDATE #{table} SET icon = CASE icon #{cases} END WHERE icon IN (#{keys})"
    end
  end

  def quote(value) = connection.quote(value)
end
