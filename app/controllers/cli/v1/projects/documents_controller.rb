# frozen_string_literal: true

module Cli
  module V1
    module Projects
      # Documenti di un progetto via CLI (CYRA-644): stessa lista del tab Documents del sito, con la
      # stessa ricerca (`?q=` su nome e nome file originale) e lo stesso filtro tag (`?tag[]=`,
      # overlap OR) — se le due risposte divergessero, chi automatizza si troverebbe un archivio
      # diverso da quello che ha davanti a video. La logica sta nei service condivisi
      # ::Projects::Documents::{Upload,Save} (sniff Marcel + limiti + cronologia), qui solo auth,
      # gate e serializzazione.
      #
      # Lettura (elenco, scheda, download) = visibilità del progetto, come sul web; caricare,
      # modificare ed eliminare = `documents.manage` sul progetto. Anti-BOLA: set_project! risolve
      # dentro visible_projects (fuori scope → R404 prima del gate) e il documento si cerca dentro
      # @project (documento di un altro progetto → R404, mai 403).
      class DocumentsController < Cli::V1::BaseController
        before_action :set_project!
        before_action -> { require_permission!("documents.manage", scope: @project) },
                      only: %i[create update destroy]
        before_action :set_document, only: %i[show update destroy download]

        def index
          records, meta = paginate(filtered_documents)
          render_ok(DocumentSerializer.new(records), meta: meta)
        end

        def show
          render_ok(DocumentSerializer.new(@document))
        end

        # Un file per chiamata (un documento È un file, come i file segreti): i metadati opzionali
        # title/description/tags viaggiano nella stessa richiesta multipart, così la cronologia
        # registra un solo evento "created".
        def create
          result = ::Projects::Documents::Upload.call(project: @project, files: [ params[:file] ],
                                                      attributes: document_attributes,
                                                      actor: Current.account, true_actor: Current.account)
          if result.ok?
            render_created(DocumentSerializer.new(result.value.first))
          else
            render_document_error(result)
          end
        end

        # Modifica PARZIALE: si aggiornano solo i campi presenti nella richiesta. Mandare i tre campi
        # sempre (come fa il form web) qui azzererebbe il nome a chi ritagga soltanto.
        def update
          result = ::Projects::Documents::Save.call(document: @document, attributes: document_attributes,
                                                    actor: Current.account, true_actor: Current.account)
          return render_ok(DocumentSerializer.new(@document)) if result.ok?

          render_document_error(result)
        end

        # Consegna il binario. Come per gli allegati KB: tipo neutro e disposition attachment, così
        # nemmeno un client che apra la risposta in un browser possa vedersela renderizzare.
        def download
          return head :not_found unless @document.file.attached?

          response.headers["X-Content-Type-Options"] = "nosniff"
          send_data @document.file.download,
                    filename: @document.sanitized_filename,
                    type: "application/octet-stream",
                    disposition: "attachment"
        end

        def destroy
          @document.destroy
          render_no_content
        end

        private

        def set_document
          @document = @project.documents.find(params[:id])
        end

        def filtered_documents
          scope = @project.documents.ordered.with_attached_file.includes(:created_by)
          scope = scope.tagged_any(tag_filter) if tag_filter.any?
          scope = scope.search(params[:q].to_s.strip) if params[:q].present?
          scope
        end

        def tag_filter
          @tag_filter ||= normalized_tags(params[:tag]) || []
        end

        # Solo le chiavi PRESENTI: la differenza fra "campo assente" (non toccarlo) e "campo vuoto"
        # (svuotalo) è tutta la semantica di una PATCH.
        def document_attributes
          attributes = {}
          attributes[:title] = params[:title].to_s if params.key?(:title)
          attributes[:description] = params[:description].to_s if params.key?(:description)
          attributes[:tags] = normalized_tags(params[:tags]) if params.key?(:tags)
          attributes
        end

        # I tag arrivano come lista (`tags[]=legal&tags[]=q3`) o come testo separato da virgole, che
        # è la forma comoda da terminale. Strip/downcase/uniq li fa poi il model.
        def normalized_tags(raw)
          return nil if raw.nil?
          return Array(raw).map(&:to_s) if raw.is_a?(Array)

          raw.to_s.split(",")
        end

        def render_document_error(result)
          render_error(result.error.code, result.error.message,
                       status: result.error.status, details: result.error.details)
        end
      end
    end
  end
end
