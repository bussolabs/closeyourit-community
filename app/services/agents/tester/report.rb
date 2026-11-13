# frozen_string_literal: true

module Agents
  module Tester
    # CYAU-329 — the Tester's outcome inside a delivery: a separate session, never the one that wrote the
    # work, ran the done criteria of the approved plan. The machine writes the block; this reads it only when
    # it has the shape of the vendored contract. A block outside it counts as no outcome: the delivery is not
    # refused, the gates that ask for the Tester leave it to a person.
    class Report
      MOMENT_DELIVERY = "delivery"
      MOMENT_STAGING = "staging"
      PASSED = "passed"
      FAILED = "failed"

      VALIDATOR = begin
        schema = Agents::Attempts::DeliveryContract::CONTRACT_SCHEMAS.fetch(2)
        JSONSchemer.schema(
          { "$schema" => schema.fetch("$schema"), "$defs" => schema.fetch("$defs"), "$ref" => "#/$defs/tester_envelope" },
          regexp_resolver: "ecma"
        )
      end

      def self.parse(block)
        new(block) if block.is_a?(Hash) && VALIDATOR.valid?(block)
      end

      def initialize(block)
        @block = block
      end

      def moment = @block.fetch("moment")
      def status = @block.fetch("status")
      def engine = @block.fetch("engine")
      def commit = @block.fetch("commit")
      def summary = @block.fetch("summary")
      def results = @block.fetch("results")
      def to_h = @block

      def status_of(criterion_id) = results.find { |entry| entry["criterion_id"] == criterion_id }&.fetch("status")
      def passed_ids = results.select { |entry| entry["status"] == PASSED }.map { |entry| entry["criterion_id"] }
    end
  end
end
