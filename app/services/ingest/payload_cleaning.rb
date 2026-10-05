# frozen_string_literal: true

module Ingest
  # Rimozione ricorsiva dei null byte da un payload grezzo (Postgres li rifiuta in text/jsonb):
  # identica in Errors/Metrics/Logs/Analytics::Ingest::Normalize, dove viveva quadruplicata.
  module PayloadCleaning
    NULL_BYTE = 0.chr

    def deep_clean(value)
      case value
      when String then value.delete(NULL_BYTE)
      when Array  then value.map { |element| deep_clean(element) }
      when Hash   then value.transform_values { |v| deep_clean(v) }
      else value
      end
    end
  end
end
