# frozen_string_literal: true

module Wikitech
  # Plain text a member sends to Wikitech (CYRA-1128): the product never receives videos or files.
  # The same text from the same source is stored once per organization (checksum), then
  # Wikitech::ProcessNoteJob turns it into cards.
  class Note < ApplicationRecord
    belongs_to :organization, class_name: "Organizations::Organization", inverse_of: :wikitech_notes
    belongs_to :created_by, class_name: "Accounts::Account", optional: true

    has_many :sources, class_name: "Wikitech::Source", inverse_of: :note, dependent: :destroy
    has_many :entries, through: :sources, source: :entry

    enum :status, { pending: 0, processed: 1, discarded: 2 }, prefix: true

    normalizes :body, with: ->(body) { LengthBudget.normalize_newlines(body).strip }
    normalizes :source_label, with: ->(label) { label.to_s.strip.presence }
    normalizes :source_url, with: ->(url) { url.to_s.strip.presence }

    validates :body, presence: true, length: { maximum: Wikitech::Constants::NOTE_BODY_MAX_CHARS }
    validates :source_label, length: { maximum: Wikitech::Constants::SOURCE_LABEL_MAX_CHARS }
    validates :checksum, presence: true

    # Same body from the same place = same note, whoever sends it and however many times.
    def self.checksum_for(body:, source_url:)
      normalized = LengthBudget.normalize_newlines(body).strip
      Digest::SHA256.hexdigest([ normalized, source_url.to_s.strip ].join("\u0000"))
    end
  end
end
