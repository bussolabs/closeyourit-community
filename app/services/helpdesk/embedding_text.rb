# frozen_string_literal: true

require "digest"

module Helpdesk
  # The text embedded for a request and its staleness checksum (CYRA-943): what the visitor wrote
  # first. Never the address, the page or the answers.
  class EmbeddingText
    def self.call(request:) = request.messages.find(&:direction_inbound?)&.body.to_s

    def self.checksum(request:)
      Digest::SHA256.hexdigest("#{Ai::Configuration.for_id(request.project.organization_id).embedding_version}\n#{call(request: request)}")
    end
  end
end
