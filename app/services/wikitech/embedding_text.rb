# frozen_string_literal: true

require "digest"

module Wikitech
  # Canonical text embedded for a card and its staleness checksum. Fixed, non-i18n labels: the same
  # card gives the same vector whatever language the reader uses.
  class EmbeddingText
    def self.call(entry:)
      [ "Name: #{entry.name}",
        ("Summary: #{entry.summary}" if entry.summary.present?),
        ("Facts: #{entry.facts.join('; ')}" if entry.facts.any?),
        ("Categories: #{entry.categories.join(', ')}" if entry.categories.any?),
        ("Repository: #{entry.repo_meta&.dig('description')}" if entry.repo_meta&.dig("description").present?) ]
        .compact.join("\n")
    end

    def self.checksum(entry:)
      Digest::SHA256.hexdigest("#{Ai::Configuration.for_id(entry.organization_id).embedding_version}\n#{call(entry: entry)}")
    end
  end
end
