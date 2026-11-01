# frozen_string_literal: true

# A card in a list: enough to choose which one to open, without facts and sources.
class WikitechEntrySummarySerializer < ApplicationSerializer
  attributes :id, :name, :summary, :categories, :repo_url, :verification, :sources_count,
             :stars, :license, :language, :updated_at
end
