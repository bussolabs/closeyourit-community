# frozen_string_literal: true

module Vulnerabilities
  module Osv
    # Record OSV → attributi della nostra tabella. Tenuto separato dalla Query perché è la traduzione
    # del formato esterno, ed è il punto dove si concentra ciò che va rivisto se OSV cambia schema.
    #
    # Della sezione `affected` conserviamo solo package e ranges: il resto (versioni enumerate una a
    # una, metadati per ecosistema) sono megabyte che non useremmo mai.
    class AdvisoryAttributes < ApplicationService
      def initialize(record:, now: Time.current)
        @record = record || {}
        @now = now
      end

      def call
        {
          aliases: Array(@record["aliases"]).map(&:to_s),
          summary: @record["summary"].presence,
          details: @record["details"].presence,
          severity: Vulnerabilities::Advisory.severity_from(database_specific["severity"]),
          cvss: cvss_vector,
          cwe_ids: Array(database_specific["cwe_ids"]).map(&:to_s),
          url: primary_url,
          affected: compact_affected,
          published_at: parse_time(@record["published"]),
          modified_at: parse_time(@record["modified"]),
          refreshed_at: @now
        }
      end

      private

      def database_specific = @record["database_specific"] || {}

      # `severity` è un array di punteggi in formati diversi (CVSS_V3, CVSS_V4). Teniamo il vettore
      # grezzo del primo: serve a chi vuole il dettaglio, non al gate del ticket automatico.
      def cvss_vector = Array(@record["severity"]).first&.dig("score").presence

      def primary_url
        references = Array(@record["references"])
        advisory = references.find { |reference| reference["type"] == "ADVISORY" }
        (advisory || references.first)&.dig("url").presence
      end

      def compact_affected
        Array(@record["affected"]).map do |entry|
          {
            "package" => {
              "name" => entry.dig("package", "name").to_s,
              "ecosystem" => entry.dig("package", "ecosystem").to_s
            },
            "ranges" => Array(entry["ranges"]).map do |range|
              { "events" => Array(range["events"]) }
            end
          }
        end
      end

      def parse_time(value)
        return nil if value.blank?

        Time.zone.parse(value.to_s)
      rescue ArgumentError
        nil
      end
    end
  end
end
