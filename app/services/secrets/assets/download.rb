# frozen_string_literal: true

module Secrets
  module Assets
    class Download
      def self.call(version:, actor:)
        encrypted = Crypto::Encrypted.new(ciphertext: version.ciphertext.download,
          wrapped_key: version.wrapped_key, key_iv: version.key_iv, key_tag: version.key_tag,
          payload_iv: version.payload_iv, payload_tag: version.payload_tag, fingerprint: version.fingerprint)
        plaintext = Crypto.decrypt(encrypted, aad: version.aad)
        RecordEvent.call(action: "downloaded", asset: version.asset, actor:, metadata: { version: version.number })
        Result.ok(plaintext)
      rescue Crypto::IntegrityError => error
        Result.err(AppError.new(error.message, code: "R422-SECRETFILE-005"))
      end
    end
  end
end
