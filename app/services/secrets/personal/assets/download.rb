# frozen_string_literal: true

module Secrets
  module Personal
    module Assets
      # Decifra una versione di file segreto personale (riusa Secrets::Assets::Crypto) e ne registra il
      # download nell'audit. IntegrityError (envelope manomesso / master key errata) → errore di dominio.
      class Download
        def self.call(version:)
          encrypted = Secrets::Assets::Crypto::Encrypted.new(
            ciphertext: version.ciphertext.download,
            wrapped_key: version.wrapped_key, key_iv: version.key_iv, key_tag: version.key_tag,
            payload_iv: version.payload_iv, payload_tag: version.payload_tag, fingerprint: version.fingerprint
          )
          plaintext = Secrets::Assets::Crypto.decrypt(encrypted, aad: version.aad)
          RecordEvent.call(action: "downloaded", asset: version.asset, metadata: { version: version.number })
          Result.ok(plaintext)
        rescue Secrets::Assets::Crypto::IntegrityError => error
          Result.err(AppError.new(error.message, code: "R422-PERSONALSECRETFILE-005"))
        end
      end
    end
  end
end
