# frozen_string_literal: true

module Vulnerabilities
  module Parse
    # `Gemfile.lock` letto con il parser di Bundler, che è già in ambiente: riscriverne uno a mano
    # significherebbe reimplementare la gestione di GEM/GIT/PATH e delle sezioni annidate, e sbagliarla.
    #
    # `specs` sono le gemme RISOLTE (tutte, con versione esatta); `dependencies` sono quelle scritte
    # nel Gemfile — da lì viene `direct`.
    class GemfileLock < ApplicationService
      def initialize(content:)
        @content = content
      end

      def call
        content = @content.to_s
        parser = ::Bundler::LockfileParser.new(content)
        declared = parser.dependencies.keys.to_set

        dependencies = parser.specs.filter_map do |spec|
          version = spec.version.to_s
          # Una gemma da path non ha una versione confrontabile con un advisory: OSV ragiona su
          # versioni pubblicate. Saltarla è più onesto che interrogare con una versione inventata.
          next if version.blank?

          Dependency.new(name: spec.name, version: version, direct: declared.include?(spec.name))
        end

        # Bundler non solleva su un file che non è un lockfile: ritorna zero specs. Senza questo
        # controllo un Gemfile.lock corrotto direbbe "nessuna dipendenza" — cioè "nessuna
        # vulnerabilità" — che è esattamente la bugia che il campo parse_error esiste per evitare.
        raise Error, "no_specs_parsed" if dependencies.empty? && content.strip.present?

        dependencies
      rescue ::Bundler::LockfileError, ArgumentError, NoMethodError => e
        raise Error, e.class.name.demodulize.underscore
      end
    end
  end
end
