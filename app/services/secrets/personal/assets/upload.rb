# frozen_string_literal: true

module Secrets
  module Personal
    module Assets
      # Carica un file segreto personale come nuova versione cifrata. RELAXED: tipo generico inferito
      # dall'estensione (un vault personale ospita file arbitrari — chiavi SSH, .npmrc, kubeconfig, .pem…),
      # nessuno sniffing di contenuto; la sicurezza viene da cap 10 MB + cifratura at-rest + download solo
      # come attachment (mai render inline → niente stored-XSS/exec). Riusa Secrets::Assets::Crypto verbatim.
      class Upload
        MAX_SIZE = 10.megabytes

        def self.call(asset:, uploaded_file:)
          new(asset:, uploaded_file:).call
        end

        def initialize(asset:, uploaded_file:)
          @asset = asset
          @uploaded_file = uploaded_file
        end

        def call
          return Result.err(AppError.new("File richiesto", code: "R422-PERSONALSECRETFILE-001")) unless @uploaded_file.respond_to?(:read)

          # Guardia anti-DoS: rifiuta PRIMA di caricare in RAM se la dimensione nota supera il cap. Il file
          # multipart è già su tempfile → .size non lo legge in memoria (l'upload di un file enorme non OOM).
          declared_size = @uploaded_file.size if @uploaded_file.respond_to?(:size)
          return Result.err(size_error) if declared_size && declared_size > MAX_SIZE

          plaintext = @uploaded_file.read
          return Result.err(size_error) unless plaintext.bytesize.between?(1, MAX_SIZE)

          version = nil
          Secrets::Personal::Asset.transaction do
            @asset.asset_type = infer_type(@uploaded_file.original_filename)
            @asset.save!
            number = @asset.versions.maximum(:number).to_i + 1
            filename = File.basename(@uploaded_file.original_filename.to_s)
            content_type = @uploaded_file.content_type.presence || "application/octet-stream"
            aad = [ "personal-secret-asset", @asset.id, "version", number, filename, content_type, plaintext.bytesize ].join(":")
            encrypted = Secrets::Assets::Crypto.encrypt(StringIO.new(plaintext), aad:)
            version = @asset.versions.create!(number:, original_filename: filename, content_type:,
              byte_size: plaintext.bytesize, wrapped_key: encrypted.wrapped_key, key_iv: encrypted.key_iv,
              key_tag: encrypted.key_tag, payload_iv: encrypted.payload_iv, payload_tag: encrypted.payload_tag,
              fingerprint: encrypted.fingerprint)
            version.ciphertext.attach(io: StringIO.new(encrypted.ciphertext), filename: "#{version.id}.enc",
                                      content_type: "application/octet-stream", identify: false)
            RecordEvent.call(action: "uploaded", asset: @asset, metadata: { version: number })
          end
          Result.ok(version)
        rescue ActiveRecord::RecordInvalid => error
          Result.err(AppError.new("Salvataggio file fallito", code: "R422-PERSONALSECRETFILE-004",
                                  details: error.record.errors.to_hash))
        ensure
          plaintext&.clear
          @uploaded_file.rewind if @uploaded_file.respond_to?(:rewind)
        end

        private

        def size_error
          AppError.new("File vuoto o superiore a 10 MiB", code: "R422-PERSONALSECRETFILE-002")
        end

        # Estensione senza punto (es. "pem", "json") come tipo generico; default "file" se assente.
        def infer_type(filename)
          File.extname(filename.to_s).downcase.delete(".").presence || "file"
        end
      end
    end
  end
end
