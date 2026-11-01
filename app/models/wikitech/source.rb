# frozen_string_literal: true

module Wikitech
  # Links a card to a note that talks about it, with the tech sentence said about the project.
  class Source < ApplicationRecord
    belongs_to :entry, class_name: "Wikitech::Entry", inverse_of: :sources, counter_cache: :sources_count
    belongs_to :note, class_name: "Wikitech::Note", inverse_of: :sources

    validates :note_id, uniqueness: { scope: :entry_id }
  end
end
