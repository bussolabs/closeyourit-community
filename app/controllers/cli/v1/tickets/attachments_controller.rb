# frozen_string_literal: true

module Cli
  module V1
    module Tickets
      # Allegati a livello ticket via CLI (screenshot/log del bug, upload multipart `files[]`). Gestione
      # riservata a chi ha `tickets.attachments.manage` sul progetto (create E destroy) — specchio di
      # Member::Tickets::AttachmentsController. La logica vive nei service condivisi
      # Ticketing::{AttachToTicket,RemoveAttachment} (sniff del tipo + limiti, R422-ATTACHMENT-001);
      # qui solo auth/gate/serializzazione. Anti-BOLA: set_project! scopa a visible_projects, il ticket
      # si risolve dentro @project (== @ticket.project) → fuori scope = R404 prima del gate.
      class AttachmentsController < Cli::V1::BaseController
        before_action :set_project!
        before_action :set_ticket
        before_action -> { require_permission!("tickets.attachments.manage", scope: @project) }, except: %i[index download]

        # Lettura/download allegati = baseline (chi vede il ticket): index e download NON gated.
        def index
          attachments, meta = paginate(@ticket.files_attachments.order(:created_at))
          render_ok(AttachmentSerializer.new(attachments), meta: meta)
        end

        # Scarica il binario: redirect all'URL del blob ActiveStorage (mai URL firmato nel serializer).
        # Unico endpoint di download per TUTTI i binari del ticket: file del ticket E file dei suoi
        # commenti (le immagini incollate nei commenti, esposte da CommentSerializer#files). Il lookup
        # resta scoped al ticket → anti-BOLA invariato (file di altro ticket/commento → R404).
        def download
          attachment = @ticket.files_attachments.find_by(id: params[:id]) ||
                       ActiveStorage::Attachment.where(record_type: "Ticketing::Comment", name: "files",
                                                       record_id: @ticket.comments.select(:id))
                                                .find(params[:id])
          redirect_to rails_blob_url(attachment.blob, disposition: "attachment")
        end

        def create
          result = Ticketing::AttachToTicket.call(
            ticket: @ticket, files: params[:files],
            actor: Current.account, true_actor: Current.account
          )
          if result.ok?
            # Ritorna la LISTA aggiornata degli allegati (reload: rilegge i blob committati).
            render_created(AttachmentSerializer.new(@ticket.files.reload))
          else
            render_error(result.error.code, result.error.message,
                         status: result.error.status, details: result.error.details)
          end
        end

        def destroy
          Ticketing::RemoveAttachment.call(
            ticket: @ticket, attachment_id: params[:id],
            actor: Current.account, true_actor: Current.account
          )
          render_no_content
        end

        private

        # Anti-BOLA: ticket dentro @project (già ristretto a visible_projects) → fuori scope = R404.
        # UUID o code umano (find_ticket! in Cli::V1::BaseController).
        def set_ticket
          @ticket = find_ticket!(@project, params[:ticket_id])
        end
      end
    end
  end
end
