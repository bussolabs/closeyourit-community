# frozen_string_literal: true

module Secrets
  module Assets
    # Ripristino di una versione storica di un file segreto: la versione scelta viene DECIFRATA e
    # ricaricata come nuova versione corrente (mai spostando un puntatore), così lo storico resta
    # integro e il ripristino è a sua volta una versione tracciata. La sorgente arriva già risolta dal
    # chiamante: il find dentro lo scope (progetto visibile / organizzazione) è anti-BOLA e deve
    # restare nel controller, qui non si autorizza nulla.
    # Il plaintext esiste solo dentro questa chiamata e viene azzerato in `ensure`: nessun ramo lo
    # restituisce, lo logga o lo mette in un metadata — l'evento porta solo i numeri di versione.
    class Rollback
      def self.call(source:, actor:)
        asset = source.asset
        downloaded = Download.call(version: source, actor:)
        return downloaded if downloaded.err?

        file = tempfile(downloaded.value)
        uploaded = ActionDispatch::Http::UploadedFile.new(tempfile: file, filename: source.original_filename,
                                                          type: source.content_type)
        result = Upload.call(asset:, uploaded_file: uploaded, actor:)
        return result if result.err?

        RecordEvent.call(action: "rolled_back", asset:, actor:,
                         metadata: { from: source.number, to: result.value.number })
        result
      ensure
        downloaded&.value&.clear if downloaded&.ok?
        file&.close!
      end

      def self.tempfile(bytes)
        file = Tempfile.new("secret-asset")
        file.binmode
        file.write(bytes)
        file.rewind
        file
      end
      private_class_method :tempfile
    end
  end
end
