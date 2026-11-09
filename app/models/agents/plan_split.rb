# frozen_string_literal: true

module Agents
  # An epic's plan may propose its child tickets and the prerequisites among them (CYRA-1152). The
  # proposal travels inside the plan, so approval, change requests and the way back to the planner are
  # the plan's own; nothing is created until a person approves it (Workflows::SplitEpic).
  class PlanSplit
    # Every child is a full round of the machines.
    MAX_CHILDREN = 8
    # The caps of the ticket a child becomes: what the person approves is the text the child is created
    # with, never cut (CYRA-1152).
    TITLE_MAX_CHARS = 255
    DESCRIPTION_MAX_CHARS = Ticketing::Constants::DESCRIPTION_MAX_CHARS
    CHILD_ID = "^CH-[1-9][0-9]*$"

    # The shape of `plan.children`, owned by the server until the canonical contract in closeyourit-docs
    # carries it: the vendored copy must stay byte for byte the pinned one (contracts-sync), so the block
    # is checked here and the rest of the result still against the vendored schema
    # (Attempts::DeliveryContract). `$defs` are the vendored v2 ones, so a child's scenarios keep the
    # shape of the plan's own.
    CONTRACT = {
      "type" => "array", "minItems" => 2, "maxItems" => MAX_CHILDREN,
      "items" => {
        "type" => "object",
        "required" => %w[id title description scenarios dependencies],
        "properties" => {
          "id" => { "type" => "string", "pattern" => CHILD_ID },
          "title" => { "type" => "string", "minLength" => 1, "maxLength" => TITLE_MAX_CHARS, "pattern" => "\\S" },
          "description" => { "type" => "string", "minLength" => 1, "maxLength" => DESCRIPTION_MAX_CHARS,
                             "pattern" => "\\S" },
          "scenarios" => { "type" => "array", "minItems" => 1, "items" => { "$ref" => "#/$defs/acceptance_scenario" } },
          "dependencies" => { "type" => "array", "uniqueItems" => true,
                              "items" => { "type" => "string", "pattern" => CHILD_ID } }
        },
        "additionalProperties" => false
      }
    }.freeze

    Child = Data.define(:id, :title, :description, :scenarios, :dependencies)

    attr_reader :children

    def self.for(plan) = new(plan&.content)

    def initialize(content)
      raw = content.is_a?(Hash) ? content.deep_stringify_keys["children"] : nil
      @children = Array(raw).filter_map { |child| build_child(child) if child.is_a?(Hash) }
    end

    def any? = children.any?
    def size = children.size

    # Why the proposal cannot stand on this ticket, or nil when it can (or when there is none).
    def problem(ticket)
      return if children.empty?
      return :not_epic unless ticket&.kind_epic?
      return :too_many if children.size > MAX_CHILDREN
      return :duplicate_child if children.map(&:id).uniq.size != children.size
      return :too_long unless children.all? { |child| fits?(child) }
      return :unknown_dependency unless dependencies_known?

      :cycle if ordered.nil?
    end

    # Every child after its prerequisites; nil when the prerequisites go round in a circle.
    def ordered
      return @ordered if defined?(@ordered)

      pending = children
      placed = []
      until pending.empty?
        ready, pending = pending.partition { |child| (child.dependencies - placed.map(&:id)).empty? }
        return @ordered = nil if ready.empty?

        placed.concat(ready)
      end
      @ordered = placed
    end

    private

    def dependencies_known?
      ids = children.map(&:id)
      children.all? { |child| (child.dependencies - ids).empty? }
    end

    # Measured as the ticket measures it, after its own normalization (Ticketing::Ticket length_budget).
    def fits?(child)
      Ticketing::Ticket.normalize_value_for(:title, child.title).to_s.length <= TITLE_MAX_CHARS &&
        Ticketing::Ticket.normalize_value_for(:description, child.description).to_s.length <= DESCRIPTION_MAX_CHARS
    end

    def build_child(child)
      Child.new(id: child["id"].to_s, title: child["title"].to_s, description: child["description"].to_s,
                scenarios: Array(child["scenarios"]).grep(Hash), dependencies: Array(child["dependencies"]).map(&:to_s))
    end
  end
end
