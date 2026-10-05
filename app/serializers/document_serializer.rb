# frozen_string_literal: true

# Documento di progetto (Projects::Document) per la CLI: metadati del record e del blob, mai l'URL
# firmato — il binario si prende dall'endpoint `download`, che lo consegna con tipo neutro e
# disposition attachment. `filename` è il nome originale del file, distinto da `title` (rinominabile).
class DocumentSerializer < ApplicationSerializer
  attributes :id, :project_id, :title, :description, :tags, :created_at, :updated_at

  attribute(:filename)     { |document| document.file.blob&.filename.to_s }
  attribute(:byte_size)    { |document| document.file.blob&.byte_size }
  attribute(:content_type) { |document| document.file.blob&.content_type }
  attribute(:author)       { |document| document.created_by&.name }
end
