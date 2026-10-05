# frozen_string_literal: true

module Secrets
  module Github
    # Cifra un valore per un GitHub Actions/Environment secret: sealed box libsodium (crypto_box_seal)
    # con la public key del repo/environment, poi base64 strict. È il formato richiesto da GitHub per
    # `encrypted_value` nella PUT del secret. La public key arriva base64 dall'endpoint public-key.
    class Encryptor < ApplicationService
      def initialize(public_key_base64:, value:)
        @public_key_base64 = public_key_base64
        @value = value.to_s
      end

      def call
        public_key = RbNaCl::PublicKey.new(Base64.decode64(@public_key_base64))
        box = RbNaCl::Boxes::Sealed.from_public_key(public_key)
        Result.ok(Base64.strict_encode64(box.box(@value)))
      end
    end
  end
end
