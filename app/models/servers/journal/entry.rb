# frozen_string_literal: true

module Servers
  module Journal
    # Riga journald immutabile (solo created_at), org-scoped come tutto Servers::. Stream append-only
    # priority <= err/crit: niente group/fingerprint/triage (come Logs::Entry). Idempotente su
    # [host, cursor] — il __CURSOR journald è la chiave di dedup sui retry dell'agent.
    class Entry < ApplicationRecord
      belongs_to :host, class_name: "Servers::Host", inverse_of: :journal_entries
      belongs_to :organization, class_name: "Organizations::Organization"

      validates :occurred_at, presence: true
      validates :priority, presence: true
      validates :message, presence: true
      validates :cursor, presence: true, uniqueness: { scope: :host_id }

      # Stream reverse-cronologico (tie-break su id per cursore stabile) — come Logs::Entry.recent.
      scope :recent, -> { order(occurred_at: :desc, id: :desc) }
    end
  end
end
