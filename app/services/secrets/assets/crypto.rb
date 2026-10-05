# frozen_string_literal: true

require "base64"
require "openssl"

module Secrets
  module Assets
    class Crypto
      ConfigurationError = Class.new(StandardError)
      IntegrityError = Class.new(StandardError)
      Encrypted = Data.define(:ciphertext, :wrapped_key, :key_iv, :key_tag, :payload_iv, :payload_tag, :fingerprint)

      class << self
        def encrypt(io, aad:)
          plaintext = io.read
          dek = SecureRandom.random_bytes(32)
          payload = encrypt_bytes(plaintext, key: dek, aad:)
          wrapped = encrypt_bytes(dek, key: master_key, aad: "#{aad}:key")
          Encrypted.new(ciphertext: payload.fetch(:data), wrapped_key: encode(wrapped.fetch(:data)),
                        key_iv: encode(wrapped.fetch(:iv)), key_tag: encode(wrapped.fetch(:tag)),
                        payload_iv: encode(payload.fetch(:iv)), payload_tag: encode(payload.fetch(:tag)),
                        fingerprint: OpenSSL::HMAC.hexdigest("SHA256", master_key, plaintext))
        ensure
          plaintext&.clear
          dek&.clear
        end

        def decrypt(encrypted, aad:)
          dek = decrypt_bytes(decode(encrypted.wrapped_key), key: master_key, aad: "#{aad}:key",
                              iv: decode(encrypted.key_iv), tag: decode(encrypted.key_tag))
          decrypt_bytes(encrypted.ciphertext, key: dek, aad:, iv: decode(encrypted.payload_iv),
                        tag: decode(encrypted.payload_tag))
        rescue OpenSSL::Cipher::CipherError, ArgumentError
          raise IntegrityError, "Secret asset authentication failed"
        ensure
          dek&.clear
        end

        private

        def master_key
          raw = Base64.strict_decode64(ENV.fetch("SECRET_ASSETS_MASTER_KEY"))
          raise ConfigurationError, "SECRET_ASSETS_MASTER_KEY must decode to 32 bytes" unless raw.bytesize == 32

          raw
        rescue KeyError, ArgumentError
          raise ConfigurationError, "SECRET_ASSETS_MASTER_KEY must be base64-encoded 32 bytes"
        end

        def encrypt_bytes(bytes, key:, aad:)
          cipher = OpenSSL::Cipher.new("aes-256-gcm").encrypt
          cipher.key = key
          iv = cipher.random_iv
          cipher.auth_data = aad
          { data: cipher.update(bytes) + cipher.final, iv:, tag: cipher.auth_tag }
        end

        def decrypt_bytes(bytes, key:, aad:, iv:, tag:)
          cipher = OpenSSL::Cipher.new("aes-256-gcm").decrypt
          cipher.key = key
          cipher.iv = iv
          cipher.auth_tag = tag
          cipher.auth_data = aad
          cipher.update(bytes) + cipher.final
        end

        def encode(value) = Base64.strict_encode64(value)
        def decode(value) = Base64.strict_decode64(value)
      end
    end
  end
end
