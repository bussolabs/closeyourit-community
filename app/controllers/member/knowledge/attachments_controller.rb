# frozen_string_literal: true

module Member
  module Knowledge
    # File allegati a una pagina KB (CYRA-176). Lettura e download = chi vede la pagina; caricare,
    # rinominare ed eliminare = chi può modificarla (autore o knowledge.edit — allegare a una pagina
    # È modificarla, quindi nessuna chiave RBAC nuova). Model SEMPRE fully-qualified ::Knowledge::*.
    #
    # Sta nel namespace knowledge e non sotto pages/ per lo stesso motivo di VersionsController: le
    # view vivono in app/views/member/knowledge/attachments/, cioè il path del controller.
    class AttachmentsController < Member::BaseController
      permission_not_required "Scaricare un allegato è baseline di chi vede la pagina; caricarlo e toglierlo sono " \
                              "gated più sotto.",
                              only: %i[download]

      include KnowledgePageManagement

      before_action :set_page
      before_action :set_attachment, only: %i[edit update destroy download]
      before_action :require_page_management, only: %i[create edit update destroy]

      def create
        result = ::Knowledge::Attachments::Upload.call(
          page: @page, files: params[:files], actor: Current.account
        )
        if result.ok?
          redirect_to member_knowledge_page_path(@page),
                      notice: t("member.knowledge.attachments.uploaded", count: result.value.length)
        else
          redirect_to member_knowledge_page_path(@page), alert: result.error.message
        end
      end

      def edit; end

      def update
        if @attachment.update(attachment_params)
          redirect_to member_knowledge_page_path(@page), notice: t("member.knowledge.attachments.updated")
        else
          @errors = @attachment.errors.to_hash
          render :edit, status: :unprocessable_content
        end
      end

      def destroy
        # Il binario lo pota ActiveStorage (has_one_attached :file → dependent: :purge_later).
        @attachment.destroy
        redirect_to member_knowledge_page_path(@page), notice: t("member.knowledge.attachments.deleted")
      end

      # Unica via di download. NON si usa rails_blob_path nelle view: qui il Content-Type è forzato a
      # binario e la disposition ad attachment, e il path non contiene il filename — che altrimenti
      # farebbe intercettare un allegato `install.php` dalla blocklist scanner di rack-attack.
      #
      # send_data e non redirect all'URL firmata: `blob.url` esige ActiveStorage::Current.url_options
      # e con il Disk service (development e test) solleva. Servire da qui funziona identico su Disk
      # e su S3, e soprattutto lascia A NOI gli header — il tipo neutro e il nosniff, che su una
      # risposta servita direttamente da S3 non potremmo impostare.
      #
      # Il file passa in memoria per il tempo della risposta (tetto 25 MB, come i secret asset che
      # usano lo stesso send_data). Niente send_stream: richiederebbe ActionController::Live, che
      # cambierebbe il modello di threading anche per edit/update/destroy di questo controller.
      def download
        # Record senza blob: impossibile dalla creazione (validazione file_present), possibile se un
        # purge è andato a metà. Meglio un 404 onesto che un 500 su file.download di nil.
        return head :not_found unless @attachment.file.attached?

        response.headers["X-Content-Type-Options"] = "nosniff"
        send_data @attachment.file.download,
                  filename: @attachment.sanitized_filename,
                  type: "application/octet-stream",
                  disposition: "attachment"
      end

      private

      # Anti-BOLA: pagina non visibile (nessuno scope in comune, o org-wide per un non-full-access)
      # → RecordNotFound, mai 403.
      def set_page
        @page = visible.pages.find(params[:page_id])
      end

      # Scoped alla pagina già risolta: un allegato di un'altra pagina è 404, non 403.
      def set_attachment
        @attachment = @page.attachments.find(params[:id])
      end

      def require_page_management
        return if page_manageable?(@page, "knowledge.edit")

        redirect_to member_knowledge_page_path(@page), alert: t("member.authorization.forbidden")
      end

      def attachment_params
        { title: params[:title], description: params[:description] }
      end
    end
  end
end
