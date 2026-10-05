# frozen_string_literal: true

module Guides
  module Installation
    class Selection < ApplicationService
      def initialize(records:, run_id: nil, version: nil)
        @records, @run_id, @version = records, run_id, version
      end

      def call
        record = @run_id.present? ? @records.find { |row| row["run_id"] == @run_id } : @records.first
        raise Invalid, "Unknown installation observation" if @run_id.present? && record.nil?
        return nil if record.nil? || (@version.present? && @version != record.dig("tuple", "package", "version"))
        record
      end
    end
  end
end
