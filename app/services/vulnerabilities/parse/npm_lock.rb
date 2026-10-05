# frozen_string_literal: true

module Vulnerabilities
  module Parse
    # `package-lock.json`. Due formati storici, entrambi ancora in circolazione:
    #
    # - v2/v3: mappa `packages` con chiavi "node_modules/<nome>" (annidate per i conflitti di
    #   versione: "node_modules/a/node_modules/b"). La chiave "" è il progetto stesso e dà `direct`.
    # - v1: albero `dependencies` ricorsivo.
    #
    # Il nome è ciò che segue l'ULTIMO "node_modules/": è la regola che gestisce l'annidamento senza
    # doverlo percorrere.
    class NpmLock < ApplicationService
      NODE_MODULES = "node_modules/"

      def initialize(content:)
        @content = content
      end

      def call
        data = JSON.parse(@content.to_s)
        raise Error, "unexpected_root" unless data.is_a?(Hash)

        packages = data["packages"]
        return from_packages(packages) if packages.is_a?(Hash)

        dependencies = data["dependencies"]
        return from_legacy_tree(dependencies) if dependencies.is_a?(Hash)

        raise Error, "missing_packages"
      rescue JSON::ParserError
        raise Error, "invalid_json"
      end

      private

      def from_packages(packages)
        declared = declared_names(packages[""])

        packages.filter_map do |key, spec|
          next unless spec.is_a?(Hash)
          # Un workspace locale (`link: true`) o il progetto stesso non sono pacchetti pubblicati.
          next if key.blank? || spec["link"]

          name = key.split(NODE_MODULES).last.to_s
          version = spec["version"].to_s
          next if name.blank? || version.blank?

          Dependency.new(name: name, version: version, direct: declared.include?(name))
        end
      end

      # v1: l'albero è ricorsivo e la profondità non è nota. Le dipendenze di primo livello sono le
      # dirette; sotto, tutto è transitivo.
      def from_legacy_tree(dependencies, depth = 0, accumulator = [])
        dependencies.each do |name, spec|
          next unless spec.is_a?(Hash)

          version = spec["version"].to_s
          accumulator << Dependency.new(name: name.to_s, version: version, direct: depth.zero?) if version.present?

          nested = spec["dependencies"]
          from_legacy_tree(nested, depth + 1, accumulator) if nested.is_a?(Hash)
        end
        accumulator
      end

      def declared_names(root)
        return Set.new unless root.is_a?(Hash)

        %w[dependencies devDependencies optionalDependencies].each_with_object(Set.new) do |section, names|
          entries = root[section]
          names.merge(entries.keys.map(&:to_s)) if entries.is_a?(Hash)
        end
      end
    end
  end
end
