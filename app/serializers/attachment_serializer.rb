# frozen_string_literal: true

# Allegato di un ticket (ActiveStorage::Attachment) per la CLI: metadati del blob, mai l'URL firmato.
class AttachmentSerializer < ApplicationSerializer
  attributes :id, :created_at

  attribute(:filename)     { |a| a.blob.filename.to_s }
  attribute(:byte_size)    { |a| a.blob.byte_size }
  attribute(:content_type) { |a| a.blob.content_type }
end
