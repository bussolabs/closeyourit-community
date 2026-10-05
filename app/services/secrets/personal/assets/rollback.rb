# frozen_string_literal: true

module Secrets
  module Personal
    module Assets
      # Gemello personale di Secrets::Assets::Rollback: stessa meccanica (la versione scelta viene
      # decifrata e ricaricata come nuova versione corrente), senza actor — nel vault personale
      # l'account È l'attore, e lo scoping [account, organization] lo ha già fatto il chiamante.
      class Rollback
        def self.call(source:)
          asset = source.asset
          downloaded = Download.call(version: source)
          return downloaded if downloaded.err?

          file = tempfile(downloaded.value)
          uploaded = ActionDispatch::Http::UploadedFile.new(tempfile: file, filename: source.original_filename,
                                                            type: source.content_type)
          result = Upload.call(asset:, uploaded_file: uploaded)
          return result if result.err?

          RecordEvent.call(action: "rolled_back", asset:,
                           metadata: { from: source.number, to: result.value.number })
          result
        ensure
          downloaded&.value&.clear if downloaded&.ok?
          file&.close!
        end

        def self.tempfile(bytes)
          file = Tempfile.new("personal-secret-asset")
          file.binmode
          file.write(bytes)
          file.rewind
          file
        end
        private_class_method :tempfile
      end
    end
  end
end
