# frozen_string_literal: true

require "digest"

module Errors
  # Testo canonico embeddato per un gruppo errori + checksum di staleness. Corto e stabile:
  # SOLO title + culprit (lo stacktrace è rumore enorme e varia tra occorrenze identiche;
  # il fingerprint resta l'identità del gruppo, l'embedding serve alla similarità semantica).
  class EmbeddingText
    def self.call(group:)
      [ group.title, group.culprit ].compact_blank.join("\n")
    end

    def self.checksum(group:)
      Digest::SHA256.hexdigest("#{Ai::Configuration.for_id(group.project.organization_id).embedding_version}\n#{call(group: group)}")
    end
  end
end
