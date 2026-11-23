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
      when Hash   then clean_hash(value)
      else value
      end
    end

    private

    # Reserve valid names before assigning collision suffixes, regardless of input order.
    # Dirty names take the first free suffix starting at 2; values remain distinct. CYRA-1218
    def clean_hash(hash)
      taken = hash.keys.reject { |key| dirty_key?(key) }.to_set
      hash.each_with_object({}) do |(key, val), cleaned|
        cleaned[dirty_key?(key) ? free_key(key.delete(NULL_BYTE), taken) : key] = deep_clean(val)
      end
    end

    def dirty_key?(key)
      key.is_a?(String) && key.include?(NULL_BYTE)
    end

    def free_key(name, taken)
      candidate = name
      suffix = 1
      candidate = "#{name}_#{suffix += 1}" while taken.include?(candidate)
      taken << candidate
      candidate
    end
  end
end
