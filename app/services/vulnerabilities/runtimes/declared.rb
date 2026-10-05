# frozen_string_literal: true

module Vulnerabilities
  module Runtimes
    # Quali runtime dichiara un repository, e in che versione. Legge i file che il team già usa per
    # fissare le versioni — non aggiunge un formato nuovo da mantenere:
    #
    #   mise.toml / .mise.toml   [tools] ruby = "3.4.2"     ← la convenzione corrente
    #   .tool-versions           ruby 3.4.2                  ← formato asdf, ancora in giro
    #   .ruby-version            3.4.2                       ← il minimo che quasi ogni repo Ruby ha
    #
    # Il nome del runtime viene tradotto nello slug di endoflife.date (`node` → `nodejs`), e ciò che
    # non è un runtime — un pacchetto npm installato via mise, un plugin — viene scartato: una
    # versione di `pnpm` non ha un calendario di fine supporto.
    class Declared < ApplicationService
      Runtime = Data.define(:name, :version, :source_path)

      FILES = %w[mise.toml .mise.toml .tool-versions .ruby-version].freeze

      # Nome dichiarato → slug endoflife.date. Solo i runtime che quel calendario copre davvero:
      # Flutter e Dart NON ci sono (404), quindi non li interroghiamo nemmeno.
      PRODUCTS = {
        "ruby" => "ruby",
        "node" => "nodejs",
        "nodejs" => "nodejs",
        "python" => "python",
        "go" => "go",
        "golang" => "go",
        "postgres" => "postgresql",
        "postgresql" => "postgresql"
      }.freeze

      def self.file?(path) = FILES.include?(File.basename(path.to_s))

      def initialize(path:, content:)
        @path = path.to_s
        @content = content.to_s
      end

      def call
        case File.basename(@path)
        when "mise.toml", ".mise.toml" then from_mise
        when ".tool-versions" then from_tool_versions
        when ".ruby-version" then from_ruby_version
        else []
        end
      end

      private

      # Il file è TOML, ma a noi serve una sola sezione con righe `chiave = "valore"`: leggerla a mano
      # evita di aggiungere una gemma TOML per tre righe. Le chiavi con backend esplicito
      # (`"npm:pnpm"`) non sono runtime e cadono da sole, perché non stanno nella mappa dei prodotti.
      def from_mise
        in_tools = false

        @content.each_line.filter_map do |line|
          line = line.strip
          next if line.empty? || line.start_with?("#")

          if line.start_with?("[")
            in_tools = line == "[tools]"
            next
          end
          next unless in_tools

          name, _, raw = line.partition("=")
          build(name.strip.delete('"'), raw.strip.delete('"'))
        end
      end

      def from_tool_versions
        @content.each_line.filter_map do |line|
          line = line.strip
          next if line.empty? || line.start_with?("#")

          name, version = line.split(/\s+/, 2)
          build(name, version)
        end
      end

      def from_ruby_version = [ build("ruby", @content.strip) ].compact

      # Una versione deve iniziare con una cifra: `lts`, `latest`, `system` e i riferimenti a un ref
      # git non dicono quale ciclo di supporto stiamo usando.
      def build(name, version)
        product = PRODUCTS[name.to_s.downcase]
        return nil if product.blank?

        version = version.to_s.strip.split(/\s+/).first.to_s
        return nil unless version.match?(/\A\d/)

        Runtime.new(name: product, version: version, source_path: @path)
      end
    end
  end
end
