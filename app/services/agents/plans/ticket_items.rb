# frozen_string_literal: true

module Agents
  module Plans
    # CYRA-1319 — a v3 plan proves the ticket's acceptance items instead of keeping a list of its own.
    # The plan's definition_of_done is a read-only record of what it was asked to prove: one entry per
    # ticket item (code, revision, text, verification) plus the items it proposes (NEW-N, `proposed`).
    # Approving the plan writes the proposals into the ticket and gives them their AC code.
    module TicketItems
      VERSION = 3

      class Stale < StandardError; end

      module_function

      def snapshot(ticket, result)
        verifications = Array(result["item_verifications"]).index_by { |entry| entry["code"] }
        existing = ticket.acceptance_items.map do |item|
          proof = verifications[item.code]
          entry(item).merge("revision" => proof&.dig("revision") || item.revision)
                     .merge(proof ? { "verification" => proof["verification"] } : {})
        end
        existing + Array(result["proposed_items"]).map { |item| proposal(item) }
      end

      def entry(item)
        base = { "id" => item.code, "revision" => item.revision, "format" => item.format, "text" => text_of(item) }
        return base unless item.scenario?

        base.merge("title" => item.title, "given" => item.step_given, "when" => item.step_when,
                   "then" => item.step_then, "expected" => item.step_expected).compact
      end

      def proposal(item)
        fields = item.slice("format", "title", "given", "when", "then", "expected", "verification").compact
        fields.merge("id" => item["ref"], "proposed" => true,
                     "text" => item["format"] == "text" ? item["text"] : item["title"].presence || item["expected"])
      end

      def text_of(item) = item.scenario? ? item.title.presence || item.step_expected : item.text

      def v3?(plan) = plan.contract_version == VERSION
      def proposed(plan) = v3?(plan) ? entries(plan).select { |entry| entry["proposed"] } : []
      def uncovered(plan) = v3?(plan) ? entries(plan).reject { |entry| entry["proposed"] || entry["verification"] } : []

      # A machine never accepts new obligations on a ticket, nor a plan that leaves an item unproven.
      def needs_person?(plan) = proposed(plan).any? || uncovered(plan).any?

      def entries(plan) = Array(plan.definition_of_done).select { |entry| entry.is_a?(Hash) }

      # Inside the approval transaction. Refuses a plan written against items that changed since; creates
      # the proposed items and rewrites the record with their real codes.
      def adopt!(plan, ticket)
        return unless v3?(plan)

        ticket.lock!
        current = ticket.acceptance_items.reload.index_by(&:code)
        planned = entries(plan).reject { |entry| entry["proposed"] }
        stale = planned.any? { |entry| current[entry["id"]]&.revision != entry["revision"] }
        raise Stale if stale || (current.keys - planned.map { |entry| entry["id"] }).any?

        position = current.values.map(&:position).max.to_i
        record = entries(plan).map do |entry|
          next entry unless entry["proposed"]

          item = create_item!(ticket, entry, position += 1)
          entry.except("proposed").merge("id" => item.code, "revision" => item.revision, "added" => true)
        end
        plan.update!(definition_of_done: record)
      end

      def create_item!(ticket, entry, position)
        if entry["format"] == "scenario"
          ticket.scenarios.create!(position:, title: entry["title"], step_given: entry["given"], step_when: entry["when"],
                                   step_then: entry["then"], step_expected: entry["expected"])
        else
          ticket.conditions.create!(position:, text: entry["text"])
        end
      end
    end
  end
end
