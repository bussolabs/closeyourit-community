# frozen_string_literal: true

module Vulnerabilities
  module Parse
    # `pnpm-lock.yaml` (lockfileVersion 6/9). Due sezioni ci interessano:
    #
    #   importers:            → cosa dichiara ogni workspace (da qui `direct`)
    #     .:
    #       dependencies:
    #         '@oclif/core': { specifier: ^4, version: 4.11.11 }
    #   packages:             → tutto ciò che è risolto, chiave "nome@versione"
    #     '@ampproject/remapping@2.3.0': { resolution: … }
    #
    # Il nome può iniziare con `@` (scope), quindi la separazione nome/versione si fa sull'ULTIMA
    # chiocciola, non sulla prima.
    class PnpmLock < ApplicationService
      def initialize(content:)
        @content = content
      end

      def call
        data = YAML.safe_load(@content.to_s, permitted_classes: [], aliases: false)
        raise Error, "missing_packages" unless data.is_a?(Hash)

        packages = data["packages"]
        raise Error, "missing_packages" unless packages.is_a?(Hash)

        declared = declared_names(data["importers"])

        packages.keys.filter_map do |key|
          name, version = split_key(key.to_s)
          next if name.blank? || version.blank?

          Dependency.new(name: name, version: version, direct: declared.include?(name))
        end
      rescue Psych::Exception => e
        raise Error, e.class.name.demodulize.underscore
      end

      private

      # "nome@1.2.3" → ["nome", "1.2.3"]; "@scope/nome@1.2.3" → ["@scope/nome", "1.2.3"].
      # Le chiavi che non hanno questa forma (tarball, link a repository) non sono confrontabili con
      # un advisory e vengono scartate.
      def split_key(key)
        # Il peer-suffix (`vitest@2.1.9(@types/node@22.20.0)`) descrive il contesto di risoluzione e
        # contiene altre chiocciole: va tolto PRIMA di cercare quella che separa nome e versione,
        # altrimenti lo split cade dentro le parentesi.
        key = key.split("(").first.to_s
        index = key.rindex("@")
        return [ nil, nil ] if index.nil? || index.zero?

        name = key[0...index]
        version = key[(index + 1)..].to_s
        return [ nil, nil ] unless version.match?(/\A\d/)

        [ name, version ]
      end

      # Ogni workspace dichiara le proprie dipendenze: l'unione è ciò che il progetto usa davvero.
      def declared_names(importers)
        return Set.new unless importers.is_a?(Hash)

        importers.each_value.with_object(Set.new) do |importer, names|
          next unless importer.is_a?(Hash)

          %w[dependencies devDependencies optionalDependencies].each do |section|
            entries = importer[section]
            names.merge(entries.keys.map(&:to_s)) if entries.is_a?(Hash)
          end
        end
      end
    end
  end
end
