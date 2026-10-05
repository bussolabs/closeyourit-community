# frozen_string_literal: true

module Vulnerabilities
  module Osv
    # Data la sezione `affected` di un advisory e il pacchetto colpito, qual è la prima versione che
    # risolve?
    #
    # Nel formato OSV ogni voce `affected` porta dei `ranges` fatti di eventi in sequenza:
    #   events: [{introduced: "7.0.0"}, {fixed: "7.0.8.1"}]
    # Un `fixed` chiude l'intervallo aperto dall'`introduced` che lo precede. Ci interessa il più
    # piccolo `fixed` MAGGIORE della versione installata: è l'aggiornamento minimo che basta.
    #
    # Un advisory può non avere alcun `fixed` (non ancora corretto, o risolvibile solo rimuovendo la
    # dipendenza): la risposta è nil, e la sezione lo dice invece di inventare un numero.
    class FixedVersion < ApplicationService
      def initialize(affected:, ecosystem:, name:, version:)
        @affected = affected
        @ecosystem = ecosystem
        @name = name
        @version = version
      end

      def call
        candidates = fixed_candidates
        return nil if candidates.empty?

        newer = candidates.select { |candidate| greater?(candidate, @version) }
        # Se nessun `fixed` risulta maggiore (versioni non confrontabili fra loro), il più piccolo
        # dichiarato resta l'indicazione più utile: meglio un riferimento che nessuno.
        pool = newer.presence || candidates
        pool.min { |a, b| compare(a, b) }
      end

      private

      def fixed_candidates
        affected_entries.flat_map do |entry|
          Array(entry["ranges"]).flat_map do |range|
            Array(range["events"]).filter_map { |event| event["fixed"].presence }
          end
        end.uniq
      end

      # Solo le voci che riguardano QUESTO pacchetto: un advisory ne elenca spesso diversi (una falla
      # in Rails tocca actionpack, activesupport, …) e il fix di uno non è il fix dell'altro.
      def affected_entries
        Array(@affected).select do |entry|
          entry = entry.deep_stringify_keys if entry.respond_to?(:deep_stringify_keys)
          package = entry["package"] || {}
          package["name"].to_s == @name.to_s && package["ecosystem"].to_s == @ecosystem.to_s
        end.map { |entry| entry.respond_to?(:deep_stringify_keys) ? entry.deep_stringify_keys : entry }
      end

      def compare(first, second)
        gem_version(first) <=> gem_version(second)
      rescue ArgumentError
        first <=> second
      end

      def greater?(candidate, reference)
        gem_version(candidate) > gem_version(reference)
      rescue ArgumentError
        # Versioni non semver (date, hash git): senza un ordine affidabile non affermiamo nulla.
        false
      end

      def gem_version(value) = Gem::Version.new(value.to_s)
    end
  end
end
