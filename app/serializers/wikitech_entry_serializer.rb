# frozen_string_literal: true

# A whole card: summary, tech facts, links, repository data and every source with its sentence.
class WikitechEntrySerializer < ApplicationSerializer
  attributes :id, :name, :summary, :categories, :repo_url, :verification, :sources_count,
             :stars, :license, :language, :updated_at, :facts, :links

  attribute(:repo) do |entry|
    meta = entry.repo_meta
    next nil if meta.blank?

    meta.slice("full_name", "stars", "license", "language", "pushed_at", "fetched_at")
  end

  attribute(:sources) do |entry|
    entry.sources.map do |source|
      { label: source.note.source_label, url: source.note.source_url,
        published_at: source.note.source_published_at, quote: source.quote }
    end
  end
end
