# frozen_string_literal: true

module Wikitech
  # One card per project (CYRA-1129): what it is for, tech facts, links, GitHub data and sources.
  # Cards with a repository merge on its normalized URL; the others on the normalized name.
  class Entry < ApplicationRecord
    # Infrastructure column vector(1024), written only by Wikitech::EmbedEntryJob.
    has_neighbors :embedding

    scope :current_embedding, -> { where(embedding_version: Ai::Configuration.current.embedding_version) }

    belongs_to :organization, class_name: "Organizations::Organization", inverse_of: :wikitech_entries

    has_many :sources, -> { order(created_at: :desc) }, class_name: "Wikitech::Source",
                                                        inverse_of: :entry, dependent: :destroy
    has_many :notes, through: :sources, source: :note

    enum :verification, { unconfirmed: 0, verified: 1 }, prefix: true

    normalizes :name, with: ->(name) { name.to_s.squish }

    validates :name, presence: true, length: { maximum: 255 }
    validates :name_key, presence: true

    before_validation { self.name_key = self.class.name_key_for(name) }

    scope :ordered, -> { order(updated_at: :desc, id: :desc) }
    scope :in_category, ->(category) { where("? = ANY (categories)", category.to_s.downcase) }
    scope :text_search, lambda { |query|
      pattern = "%#{sanitize_sql_like(query.to_s.strip)}%"
      where("wikitech_entries.name ILIKE :p OR wikitech_entries.summary ILIKE :p OR " \
            "array_to_string(wikitech_entries.facts, ' ') ILIKE :p", p: pattern)
    }

    def self.name_key_for(name) = name.to_s.downcase.gsub(/[^a-z0-9]+/, "")

    def stars = repo_meta&.dig("stars")
    def license = repo_meta&.dig("license")
    def language = repo_meta&.dig("language")
  end
end
