# frozen_string_literal: true

module Dev
  # Personas di sviluppo per il prefill del login. Disponibili SOLO in development
  # (fuori da development ritorna sempre [] → il <select> non viene renderizzato).
  module Personas
    PATH = Rails.root.join("db/seeds/dev_personas.yml")

    def self.all
      return [] unless Rails.env.development?
      return [] unless File.exist?(PATH)

      YAML.load_file(PATH).map(&:symbolize_keys)
    end
  end
end
