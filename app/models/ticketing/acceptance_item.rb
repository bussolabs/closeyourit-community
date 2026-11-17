module Ticketing
  # CYRA-1317 — one acceptance item of a ticket: something that must be true at the end, written as plain
  # text (Ticketing::Condition) or as a Given/When/Then/Expected case (Ticketing::Scenario). The ticket is
  # its only source: plans add how to prove each item and never keep a list of their own.
  # `code` (AC-N) is never reused on its ticket; `revision` grows on every content change, so an approved
  # plan can tell whether the item it approved is still the same.
  class AcceptanceItem < ApplicationRecord
    self.table_name = "ticketing_acceptance_items"
    self.inheritance_column = "format"

    FORMATS = { "scenario" => "Ticketing::Scenario", "text" => "Ticketing::Condition" }.freeze
    CONTENT_FIELDS = %w[title text step_given step_when step_then step_expected].freeze
    CODE_PATTERN = /\AAC-[1-9]\d*\z/

    belongs_to :ticket, class_name: "Ticketing::Ticket"

    scope :ordered, -> { order(:position, :created_at) }

    before_create :assign_code
    before_update :bump_revision

    def self.sti_name = FORMATS.key(name)
    def self.find_sti_class(format) = FORMATS.fetch(format.to_s).constantize

    # CYRA-1318 — the CLI sends the whole list at once. An item with a known code is updated in place, so it
    # keeps its code; one without a code is new; an item left out is removed. Returns the nested attributes of
    # the two formats, both always present, so a list of only one format still removes the other.
    def self.nested_attributes_for(ticket, rows)
      existing = ticket ? ticket.acceptance_items.index_by(&:code) : {}
      kept = []
      nested = { scenarios_attributes: [], conditions_attributes: [] }
      Array(rows).each_with_index do |row, position|
        row = row.to_h.stringify_keys
        item = existing[row["code"]]
        kept << item.code if item
        scenario = (row["format"] || item&.format) == "scenario"
        fields = scenario ? row.slice("title", *Ticketing::Scenario::STEP_FIELDS.map(&:to_s)) : row.slice("text")
        attributes = fields.merge("position" => position, "id" => (item.id if item && item.scenario? == scenario)).compact
        nested[scenario ? :scenarios_attributes : :conditions_attributes] << attributes
      end
      (existing.values.reject { kept.include?(it.code) }).each do |item|
        nested[item.scenario? ? :scenarios_attributes : :conditions_attributes] << { "id" => item.id, "_destroy" => true }
      end
      nested
    end

    def scenario? = format == "scenario"

    # The wire shape for the CLI and the agents: the code and revision a plan refers to, then the content.
    def to_payload
      { code:, revision:, format:, title:, text:, step_given:, step_when:, step_then:, step_expected: }.compact
    end

    private

    # Atomic on the ticket row: two saves at once never get the same number.
    def assign_code
      return if code.present?

      number = self.class.connection.select_value(self.class.sanitize_sql_array([ <<~SQL.squish, ticket_id ]))
        UPDATE ticketing_tickets SET last_acceptance_item_number = last_acceptance_item_number + 1
        WHERE id = ? RETURNING last_acceptance_item_number
      SQL
      self.code = "AC-#{number}"
    end

    def bump_revision
      self.revision += 1 if (changed & CONTENT_FIELDS).any?
    end
  end
end
