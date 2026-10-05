# frozen_string_literal: true

# Commento di un ticket per la CLI. `author` = nome dell'autore (umano), come le label in TicketSerializer.
# `files` = metadati degli allegati del commento (stesso shape di AttachmentSerializer, mai l'URL firmato):
# senza, le immagini incollate nei commenti sarebbero invisibili da CLI. Il binario passa SOLO dal
# download endpoint del ticket (Cli::V1::Tickets::AttachmentsController#download).
#
# `kind` distingue una riga scritta dall'app da un messaggio di una persona (CYRA-221). Serve ai
# lettori del ciclo di chiarimenti: `ANY_MARKER_PATTERN` dell'automator considera RISPOSTA DEL CLIENTE
# qualunque commento senza marker autopilot, quindi senza questo campo una riga di servizio ("Resoconto
# aggiornato alla versione 2") sbloccherebbe un ticket a cui nessuno ha risposto.
class CommentSerializer < ApplicationSerializer
  attributes :id, :ticket_id, :body, :kind, :created_at, :updated_at

  attribute(:author) { |comment| comment.author&.name }
  attribute(:files) do |comment|
    comment.files_attachments.map do |attachment|
      {
        id: attachment.id,
        filename: attachment.blob.filename.to_s,
        content_type: attachment.blob.content_type,
        byte_size: attachment.blob.byte_size,
        created_at: attachment.created_at
      }
    end
  end
end
