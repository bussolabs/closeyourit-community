# frozen_string_literal: true

# A note as the CLI sees it after sending it: its state, never the body it already has.
class WikitechNoteSerializer < ApplicationSerializer
  attributes :id, :status, :source_label, :source_url, :source_published_at, :links, :created_at
end
