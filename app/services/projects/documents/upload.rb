# frozen_string_literal: true

module Projects
  module Documents
    # Carica N file come N documenti del progetto (title iniziale = filename originale, poi
    # rinominabile). Pre-valida TUTTI i file prima di creare qualsiasi record (all-or-nothing,
    # come Ticketing::AttachToTicket): un lotto con un file invalido non crea nulla.
    class Upload < ApplicationService
      # `attributes` sono i metadati opzionali del canale CLI (title/description/tags dichiarati
      # nella stessa chiamata dell'upload): applicarli QUI invece che con un Save subito dopo tiene
      # la cronologia onesta — un caricamento è UN evento "created", non un created seguito da un
      # updated che nessuno ha fatto. Il `title` esplicito vale solo per il caricamento di un file
      # solo: su un lotto darebbe N documenti con lo stesso nome, e il nome del file è più utile.
      def initialize(project:, files:, attributes: {}, actor: nil, true_actor: nil)
        @project = project
        @files = Array.wrap(files).reject(&:blank?)
        @attributes = attributes.to_h.compact
        @actor = actor
        @true_actor = true_actor
      end

      def call
        return err(:no_files) if @files.empty?
        return err(:invalid_file) unless @files.all? { |file| allowed?(file) }

        documents = ApplicationRecord.transaction do
          @files.map do |file|
            document = @project.documents.new(title: file.original_filename, created_by: @actor)
            document.assign_attributes(document_attributes)
            document.file.attach(file)
            document.save!
            Activity::Record.call(subject: document, action: "created", actor: @actor, true_actor: @true_actor)
            document
          end
        end
        Result.ok(documents)
      end

      private

      def document_attributes
        return @attributes if @files.one?

        @attributes.except(:title, "title")
      end

      # Tipo SNIFFATO da Marcel sui byte reali (come fa ActiveStorage al build del blob),
      # NON il content-type dichiarato dal client (spoofabile).
      #
      # Il primo controllo è sulla FORMA: dal canale CLI `file` è un parametro qualsiasi, e un client
      # che manda `file=notes.txt` invece del multipart consegnerebbe una String — che qui esploderebbe
      # su `tempfile` come errore del server invece di essere un 422 leggibile.
      def allowed?(file)
        return false unless file.respond_to?(:tempfile)

        sniffed = Marcel::MimeType.for(file.tempfile, name: file.original_filename, declared_type: file.content_type)
        Projects::Document.allowed_file?(content_type: sniffed, byte_size: file.size)
      end

      def err(key)
        Result.err(AppError.new(I18n.t("member.documents.errors.#{key}"),
                                code: "R422-DOCUMENT-001"))
      end
    end
  end
end
