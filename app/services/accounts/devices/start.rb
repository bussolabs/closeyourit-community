# frozen_string_literal: true

module Accounts
  module Devices
    # Device-authorization request (RFC 8628 §3.1-3.2). Crea la concessione e ritorna il device_code
    # (opaco, mostrato UNA volta alla CLI) + il user_code (mostrato all'umano nel browser).
    class Start < ApplicationService
      DEVICE_CODE_BYTES = 32

      def initialize(client_name: nil)
        @client_name = client_name
      end

      def call
        device_code = SecureRandom.urlsafe_base64(DEVICE_CODE_BYTES)

        grant = Accounts::DeviceGrant.create!(
          device_code_digest: Digest::SHA256.hexdigest(device_code),
          user_code: generate_user_code,
          client_name: @client_name,
          interval: Accounts::Constants::DEVICE_POLL_INTERVAL,
          expires_at: Accounts::Constants::TTL_DEVICE_GRANT.from_now
        )

        Result.ok({ grant:, device_code: })
      end

      private

      # Due gruppi da 4 caratteri ("WDJB-MZHN"), univoco (retry su collisione dell'indice unique).
      def generate_user_code
        loop do
          code = "#{sample(4)}-#{sample(4)}"
          return code unless Accounts::DeviceGrant.exists?(user_code: code)
        end
      end

      def sample(length)
        alphabet = Accounts::Constants::DEVICE_USER_CODE_ALPHABET
        Array.new(length) { alphabet[SecureRandom.random_number(alphabet.length)] }.join
      end
    end
  end
end
