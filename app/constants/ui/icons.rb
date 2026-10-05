# frozen_string_literal: true

module Ui
  # Curated Lucide icons a project or group can pick: the allow-list of `Iconable` and the picker.
  # FONT_AWESOME_NAMES maps the names stored before Lucide, still sent by older CLI scripts. CYRA-926
  module Icons
    NAMES = %w[
      rocket bug gauge server smartphone globe database code
      flask-conical shield-half bolt box layers terminal cloud settings
      flame star flag package plug workflow microchip network
      boxes gem bot compass puzzle radio-tower satellite-dish wand-sparkles
    ].freeze

    FONT_AWESOME_NAMES = {
      "gauge-high" => "gauge", "mobile-screen" => "smartphone", "flask-vial" => "flask-conical",
      "shield-halved" => "shield-half", "cube" => "box", "layer-group" => "layers", "gear" => "settings",
      "fire" => "flame", "flag-checkered" => "flag", "diagram-project" => "workflow", "sitemap" => "network",
      "cubes" => "boxes", "robot" => "bot", "puzzle-piece" => "puzzle", "tower-broadcast" => "radio-tower",
      "wand-magic-sparkles" => "wand-sparkles"
    }.freeze

    def self.valid?(name) = NAMES.include?(name.to_s)

    def self.normalize(name)
      name = name.to_s.strip.downcase.delete_prefix("fa-").presence
      FONT_AWESOME_NAMES.fetch(name, name)
    end
  end
end
