# frozen_string_literal: true

module Cli
  module V1
    module Knowledge
      # File allegati a una pagina KB via CLI (upload multipart `files[]`). Specchio di
      # Member::Knowledge::AttachmentsController e di Cli::V1::Tickets::AttachmentsController: la
      # logica sta nel service condiviso ::Knowledge::Attachments::Upload (sniff Marcel + limiti,
      # R422-KNOWLEDGE-008), qui solo auth, gate e serializzazione.
      #
      # Lettura e download = baseline di chi vede la pagina; caricare ed eliminare = chi può
      # modificarla (autore o knowledge.edit su tutti i progetti effettivi), come sul canale web.
      class AttachmentsController < Cli::V1::BaseController
        before_action :set_page
        before_action :set_attachment, only: %i[destroy download]

        def index
          attachments, meta = paginate(@page.attachments.with_attached_file)
          render_ok(KnowledgeAttachmentSerializer.new(attachments), meta: meta)
        end

        # Consegna il binario. Come sul web: tipo neutro e disposition attachment, così nemmeno un
        # client che apra la risposta in un browser possa vedersela renderizzare.
        def download
          return head :not_found unless @attachment.file.attached?

          response.headers["X-Content-Type-Options"] = "nosniff"
          send_data @attachment.file.download,
                    filename: @attachment.sanitized_filename,
                    type: "application/octet-stream",
                    disposition: "attachment"
        end

        def create
          return unless page_manageable!

          result = ::Knowledge::Attachments::Upload.call(page: @page, files: params[:files], actor: Current.account)
          if result.ok?
            render_created(KnowledgeAttachmentSerializer.new(result.value))
          else
            render_error(result.error.code, result.error.message,
                         status: result.error.status, details: result.error.details)
          end
        end

        def destroy
          return unless page_manageable!

          @attachment.destroy
          render_no_content
        end

        private

        # Anti-BOLA: pagina risolta tra quelle visibili all'account (fuori scope → R404).
        def set_page
          @page = visible_pages.find(params[:page_id])
        end

        def set_attachment
          @attachment = @page.attachments.find(params[:id])
        end

        def visible_pages
          ::Knowledge::Page.visible_to(account: Current.account, organization: Current.organization,
                                       visible_project_ids: visible_projects.select(:id),
                                       visible_group_ids: visible_groups.select(:id))
        end

        # Stessa regola del canale web (KnowledgePageManagement) e di Cli::V1::Knowledge::Pages:
        # serve vedere l'intero scope della pagina, poi esserne autore o avere knowledge.edit su
        # TUTTI i progetti effettivi (pagina org-wide → solo accesso pieno).
        def page_manageable!
          unless full_scope_access?
            render_error("R403-CLIAUTH-002", "Permesso negato", status: :forbidden)
            return false
          end
          return true if @page.authored_by?(Current.account)

          projects = @page.effective_projects.to_a
          allowed = if projects.empty?
                      Authorization::VisibleScope.unscoped?(account: Current.account,
                                                            organization: Current.organization)
          else
                      projects.all? { |project| authorization.can?("knowledge.edit", scope: project) }
          end
          return true if allowed

          render_error("R403-CLIAUTH-002", "Permesso negato", status: :forbidden)
          false
        end

        def full_scope_access?
          !@page.effective_projects.where.not(id: visible_projects.select(:id)).exists?
        end
      end
    end
  end
end
