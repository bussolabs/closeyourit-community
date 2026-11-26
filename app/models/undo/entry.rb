# frozen_string_literal: true

module Undo
  # CYRA-1150 — what one bulk action changed: for each row, the written columns before and after. Only its
  # author can undo it, and only until `expires_at`; Undo::PruneJob deletes the expired ones.
  class Entry < ApplicationRecord
    self.table_name = "undo_entries"

    # The toast offers Undo for 10 seconds; the entry outlives it a little, so a late click still lands.
    TTL = 15.seconds

    # The columns a bulk action writes and an undo puts back. Errors carry the release audit and the
    # resolution notes too: undoing a resolve must give back the notes written before (Errors::Triage).
    KINDS = {
      "error_groups" => { model: "Errors::Group",
                          columns: %w[status resolved_in_release regressed_in_release resolution_cause resolution_fix] },
      "metric_groups" => { model: "Metrics::Group", columns: %w[status] },
      "notifications" => { model: "Alerting::Notification", columns: %w[read_at] }
    }.freeze

    belongs_to :organization, class_name: "Organizations::Organization"
    belongs_to :account, class_name: "Accounts::Account"

    validates :kind, inclusion: { in: KINDS.keys }

    scope :expired, -> { where(expires_at: ..Time.current) }

    # Runs the action on the rows locked FOR UPDATE and records what it changed, in one transaction: no
    # other write slips between reading "before" and the action. Returns [block value, entry or nil].
    def self.capture(kind:, account:, organization:, ids:)
      model = model_for(kind)
      transaction do
        before = model.where(id: ids).order(:id).lock.to_a.to_h { |row| [ row.id, snapshot(row, kind) ] }
        value = yield
        items = model.where(id: before.keys).order(:id).filter_map do |row|
          after = snapshot(row, kind)
          { "id" => row.id, "before" => before[row.id], "after" => after } unless after == before[row.id]
        end
        entry = create!(kind:, account:, organization:, items:, expires_at: TTL.from_now) if items.any?
        [ value, entry ]
      end
    end

    def self.model_for(kind) = KINDS.fetch(kind)[:model].constantize

    def self.snapshot(row, kind)
      KINDS.fetch(kind)[:columns].to_h { |column| [ column, dump(row.public_send(column)) ] }
    end

    # Times as microsecond strings, the database precision: the comparison after a round trip holds.
    def self.dump(value) = value.respond_to?(:utc) ? value.utc.iso8601(6) : value

    def model = self.class.model_for(kind)
    def item_ids = items.pluck("id")
    def expired? = expires_at <= Time.current
  end
end
