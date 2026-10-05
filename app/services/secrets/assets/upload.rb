# frozen_string_literal: true

module Secrets
  module Assets
    class Upload
      MAX_SIZE = 10.megabytes
      EXTENSIONS = { ".p8" => "p8", ".p12" => "p12", ".jks" => "jks", ".keystore" => "keystore", ".json" => "service_account_json" }.freeze

      def self.call(asset:, uploaded_file:, actor:)
        new(asset:, uploaded_file:, actor:).call
      end

      def initialize(asset:, uploaded_file:, actor:)
        @asset, @uploaded_file, @actor = asset, uploaded_file, actor
      end

      def call
        return Result.err(AppError.new("File richiesto", code: "R422-SECRETFILE-001")) unless @uploaded_file.respond_to?(:read)

        plaintext = @uploaded_file.read
        type = EXTENSIONS[File.extname(@uploaded_file.original_filename.to_s).downcase]
        return Result.err(AppError.new("Tipo file non supportato", code: "R422-SECRETFILE-001")) unless type
        return Result.err(AppError.new("File vuoto o superiore a 10 MiB", code: "R422-SECRETFILE-002")) unless plaintext.bytesize.between?(1, MAX_SIZE)
        return Result.err(AppError.new("Contenuto file non valido", code: "R422-SECRETFILE-003")) unless valid_content?(type, plaintext)

        version = nil
        Asset.transaction do
          @asset.asset_type = type
          @asset.save!
          number = @asset.versions.maximum(:number).to_i + 1
          filename = File.basename(@uploaded_file.original_filename.to_s)
          content_type = @uploaded_file.content_type.presence || "application/octet-stream"
          aad = [ "secret-asset", @asset.id, "version", number, filename, content_type, plaintext.bytesize ].join(":")
          encrypted = Crypto.encrypt(StringIO.new(plaintext), aad:)
          version = @asset.versions.create!(number:, original_filename: filename,
            content_type:, byte_size: plaintext.bytesize,
            wrapped_key: encrypted.wrapped_key, key_iv: encrypted.key_iv, key_tag: encrypted.key_tag,
            payload_iv: encrypted.payload_iv, payload_tag: encrypted.payload_tag, fingerprint: encrypted.fingerprint,
            created_by: @actor)
          version.ciphertext.attach(io: StringIO.new(encrypted.ciphertext), filename: "#{version.id}.enc",
                                    content_type: "application/octet-stream", identify: false)
          RecordEvent.call(action: "uploaded", asset: @asset, actor: @actor, metadata: { version: number })
        end
        Result.ok(version)
      rescue ActiveRecord::RecordInvalid => error
        Result.err(AppError.new("Salvataggio asset fallito", code: "R422-SECRETFILE-004",
                                details: error.record.errors.to_hash))
      ensure
        plaintext&.clear
        @uploaded_file.rewind if @uploaded_file.respond_to?(:rewind)
      end

      private

      def valid_content?(type, bytes)
        case type
        when "p8" then bytes.include?("PRIVATE KEY")
        when "p12" then OpenSSL::ASN1.decode(bytes).present?
        when "jks" then bytes.start_with?([ 0xFEEDFEED ].pack("N"))
        when "keystore" then bytes.start_with?([ 0xFEEDFEED ].pack("N"), [ 0xCECECECE ].pack("N"))
        when "service_account_json"
          json = JSON.parse(bytes)
          json["type"] == "service_account" && json.values_at("project_id", "private_key", "client_email").all?(&:present?)
        end
      rescue JSON::ParserError, OpenSSL::ASN1::ASN1Error
        false
      end
    end
  end
end
