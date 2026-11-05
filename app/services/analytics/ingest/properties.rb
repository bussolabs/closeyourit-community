# frozen_string_literal: true

module Analytics
  module Ingest
    # Cleans the properties of one event (CYRA-1158): scalar values only, the first ten that survive,
    # short names and values. A property is dropped whole when its name or its value looks personal.
    class Properties < ApplicationService
      include ::Ingest::PiiScrubbing

      PHONE_SHAPE = /\A\+?[\d\s().\-]{7,25}\z/
      PHONE_DIGITS = (7..15)
      ISO_DATE = /\A\d{4}-\d{2}-\d{2}\z/
      CARD_SHAPE = /\A[\d \-]{13,23}\z/
      CARD_DIGITS = (13..19)

      def initialize(raw:)
        @raw = raw.is_a?(Hash) ? raw : {}
      end

      def call
        @raw.each_with_object({}) do |(key, value), kept|
          break kept if kept.size >= Constants::EVENT_PROPERTIES_MAX

          name = key.to_s.strip.slice(0, Constants::EVENT_PROPERTY_NAME_MAX_LENGTH)
          cleaned = clean_value(value)
          next if name.empty? || cleaned.nil? || sensitive_key?(name) || personal_value?(cleaned)

          kept[name] = cleaned
        end
      end

      private

      def clean_value(value)
        case value
        when String then value.strip.slice(0, Constants::EVENT_PROPERTY_VALUE_MAX_LENGTH).presence
        when Integer, true, false then value
        when Float then value.finite? ? value : nil
        end
      end

      def personal_value?(value)
        return card_number?(value.to_s) if value.is_a?(Integer)
        return false unless value.is_a?(String)

        EMAIL_IN_TEXT.match?(value) || phone_number?(value) || card_number?(value)
      end

      def phone_number?(value)
        PHONE_SHAPE.match?(value) && !ISO_DATE.match?(value) && PHONE_DIGITS.cover?(value.count("0-9"))
      end

      # Luhn check, so an order number of the same length does not count as a card.
      def card_number?(value)
        return false unless CARD_SHAPE.match?(value)

        digits = value.delete("^0-9").chars.map(&:to_i)
        return false unless CARD_DIGITS.cover?(digits.size)

        sum = digits.reverse.each_with_index.sum { |digit, index| index.odd? ? (digit * 2).divmod(10).sum : digit }
        (sum % 10).zero?
      end
    end
  end
end
