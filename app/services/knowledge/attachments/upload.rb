# frozen_string_literal: true

module Knowledge
  module Attachments
    # Carica N file come N allegati della pagina (title iniziale = filename originale, poi
    # rinominabile). Pre-valida TUTTI i file prima di creare qualsiasi record (all-or-nothing, come
    # Projects::Documents::Upload e Ticketing::AttachToTicket): un lotto con un file invalido non
    # crea nulla.
    class Upload < ApplicationService
      def initialize(page:, files:, actor: nil)
        @page = page
        @files = Array.wrap(files).reject(&:blank?)
        @actor = actor
      end

      def call
        return err(:no_files) if @files.empty?
        return err(:invalid_file) unless @files.all? { |file| allowed?(file) }

        attachments = ApplicationRecord.transaction do
          @files.map do |file|
            attachment = @page.attachments.new(title: file.original_filename, created_by: @actor)
            attachment.file.attach(file)
            attachment.save!
            attachment
          end
        end
        Result.ok(attachments)
      end

      private

      # Tipo SNIFFATO da Marcel sui byte reali, NON il content-type dichiarato dal client
      # (spoofabile) né l'estensione. È l'UNICO gate reale: la pagina è già persistita, quindi
      # `attach` committerebbe il blob prima che la validazione del model possa dire la sua.
      #
      # Limite noto e accettato: un frammento HTML senza doctype non ha magic byte e Marcel lo
      # classifica text/plain, che è ammesso. Non è un buco sfruttabile perché text/plain non è
      # renderizzabile inline (config/initializers/active_storage.rb) — il browser lo scarica.
      def allowed?(file)
        sniffed = Marcel::MimeType.for(file.tempfile, name: file.original_filename, declared_type: file.content_type)
        Knowledge::Attachment.allowed_file?(content_type: sniffed, byte_size: file.size)
      end

      def err(key)
        Result.err(AppError.new(I18n.t("member.knowledge.attachments.errors.#{key}"),
                                code: "R422-KNOWLEDGE-008"))
      end
    end
  end
end
