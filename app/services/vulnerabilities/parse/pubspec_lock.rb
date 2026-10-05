# frozen_string_literal: true

module Vulnerabilities
  module Parse
    # `pubspec.lock` (Dart/Flutter). Forma:
    #
    #   packages:
    #     http:
    #       dependency: "direct main"   # oppure "transitive" / "direct dev"
    #       version: "0.13.0"
    #
    # `YAML.safe_load` e non `YAML.load`: il contenuto arriva da un repository esterno e il load
    # permissivo istanzia oggetti Ruby arbitrari.
    class PubspecLock < ApplicationService
      DIRECT_PREFIX = "direct"

      def initialize(content:)
        @content = content
      end

      def call
        data = YAML.safe_load(@content.to_s, permitted_classes: [], aliases: false)
        packages = data.is_a?(Hash) ? data["packages"] : nil
        raise Error, "missing_packages" unless packages.is_a?(Hash)

        packages.filter_map do |name, spec|
          next unless spec.is_a?(Hash)

          version = spec["version"].to_s
          next if version.blank?

          Dependency.new(name: name.to_s, version: version,
                         direct: spec["dependency"].to_s.start_with?(DIRECT_PREFIX))
        end
      rescue Psych::Exception => e
        raise Error, e.class.name.demodulize.underscore
      end
    end
  end
end
