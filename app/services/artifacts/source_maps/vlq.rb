# frozen_string_literal: true

module Artifacts
  module SourceMaps
    module Vlq
      DIGITS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".bytes.each_with_index.to_h.freeze
      module_function

      def decode(segment)
        fields = []
        value = shift = 0
        segment.each_byte do |byte|
          digit = DIGITS[byte]
          raise Rejected, "invalid_vlq" unless digit
          value |= (digit & 31) << shift
          raise Rejected, "vlq_overflow" if value > 0xffffffff || shift > 30
          if (digit & 32).zero?
            fields << (value == 1 ? -(2**31) : ((value & 1).zero? ? value >> 1 : -(value >> 1)))
            raise Rejected, "invalid_segment" if fields.size > 5
            value = shift = 0
          else
            shift += 5
          end
        end
        raise Rejected, "invalid_vlq" unless shift.zero?
        raise Rejected, "invalid_segment" unless [ 1, 4, 5 ].include?(fields.size)
        fields
      end
    end
  end
end
