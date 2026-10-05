# frozen_string_literal: true

require "openssl"
require "base64"
require "json"

module Github
  # JWT dell'App GitHub, firmato RS256 con la private key dell'App (ENV GH_APP_PRIVATE_KEY, mai
  # persistita nel DB). `iss` = App ID, `exp` ≤ 10 min (limite GitHub). Serve solo per coniare gli
  # installation-token; le chiamate API usano poi il token dell'installazione.
  class AppJwt
    EXPIRY_SECONDS = 9 * 60 # < 10 min imposto da GitHub
    CLOCK_SKEW_SECONDS = 60

    def initialize(app_id: Settings::Integrations.value(:gh_app_id) || raise(KeyError, "GH_APP_ID"),
                   private_key: Settings::Integrations.value(:gh_app_private_key) || raise(KeyError, "GH_APP_PRIVATE_KEY"),
                   now: Time.current)
      @app_id = app_id
      @private_key = private_key
      @now = now
    end

    def to_s
      header = { alg: "RS256", typ: "JWT" }
      payload = {
        iat: (@now - CLOCK_SKEW_SECONDS).to_i,
        exp: (@now + EXPIRY_SECONDS).to_i,
        iss: @app_id.to_s
      }
      signing_input = "#{encode(header)}.#{encode(payload)}"
      signature = rsa_key.sign(OpenSSL::Digest.new("SHA256"), signing_input)
      "#{signing_input}.#{base64url(signature)}"
    end

    private

    # La private key arriva da ENV: passando i secret multilinea da CloseYourIt→Kamal→container i newline
    # vengono escapati in `\n` letterale (backslash-n), che OpenSSL non parsa → RSAError. De-escapiamo
    # in newline veri. No-op se la key ha già i newline reali (dev / cyi run locale).
    def rsa_key = OpenSSL::PKey::RSA.new(@private_key.to_s.gsub('\n', "\n"))
    def encode(data) = base64url(JSON.generate(data))
    def base64url(bytes) = Base64.urlsafe_encode64(bytes, padding: false)
  end
end
