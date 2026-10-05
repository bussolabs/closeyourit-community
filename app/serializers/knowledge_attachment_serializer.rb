# frozen_string_literal: true

# Allegato di una pagina KB per la CLI: metadati, mai l'URL firmato del blob (il binario si prende
# dall'endpoint `download`, che forza tipo neutro e disposition attachment).
class KnowledgeAttachmentSerializer < ApplicationSerializer
  attributes :id, :title, :description, :created_at

  attribute(:filename)     { |a| a.file.blob&.filename.to_s }
  attribute(:byte_size)    { |a| a.file.blob&.byte_size }
  attribute(:content_type) { |a| a.file.blob&.content_type }
  # Dichiarato nel payload perché un client automatico deve poter distinguere uno script da un
  # documento senza reimplementare l'allowlist.
  attribute(:script) { |a| Knowledge::Constants::SCRIPT_CONTENT_TYPES.include?(a.file.blob&.content_type) }
end
