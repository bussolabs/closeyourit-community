# frozen_string_literal: true

module Wikitech
  # Puts one extracted item into the organization's cards (CYRA-1129): a card that already exists
  # for the same repository (or, without a repository, the same name) gains facts and a source
  # instead of being duplicated. The first summary stays: a later note does not rewrite the card.
  class MergeItem < ApplicationService
    LINKS_MAX = 20

    def initialize(note:, item:)
      @note = note
      @item = item
    end

    def call
      attempts ||= 0
      entry = find_or_build
      apply(entry)
      ActiveRecord::Base.transaction do
        entry.save!
        entry.sources.find_or_create_by!(note: @note) { |source| source.quote = @item.quote }
      end
      Result.ok(entry)
    rescue ActiveRecord::RecordNotUnique
      # Another note created the same repository card in the meantime: merge into that one.
      attempts += 1
      retry if attempts == 1
      raise
    end

    private

    def entries = @note.organization.wikitech_entries

    def find_or_build
      by_repo = entries.find_by(repo_url: @item.repo_url) if @item.repo_url
      by_repo || by_name || entries.new(name: @item.name)
    end

    # Without a repository on either side the name decides; a card with a different repository is
    # a different project that happens to share the name.
    def by_name
      candidates = entries.where(name_key: Wikitech::Entry.name_key_for(@item.name))
      candidates = candidates.where(repo_url: nil) if @item.repo_url
      candidates.order(:created_at).first
    end

    def apply(entry)
      entry.repo_url ||= @item.repo_url
      entry.summary = @item.summary if entry.summary.blank?
      entry.facts = merged(entry.facts, @item.facts, Wikitech::Constants::FACTS_MAX)
      entry.categories = merged(entry.categories, @item.categories, Wikitech::Constants::CATEGORIES_MAX)
      entry.links = merged(entry.links, @item.links - [ entry.repo_url ], LINKS_MAX)
    end

    def merged(current, incoming, max)
      known = current.map(&:downcase)
      (current + incoming.reject { |value| known.include?(value.downcase) }).uniq(&:downcase).first(max)
    end
  end
end
