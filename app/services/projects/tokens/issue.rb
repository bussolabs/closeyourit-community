# frozen_string_literal: true

module Projects
  module Tokens
    # Emette una nuova credenziale di ingest per un progetto. Genera il segreto bearer (mostrato UNA
    # sola volta nel Result) + la DSN public key. In DB finisce solo il digest SHA-256 del segreto.
    class Issue < ApplicationService
      SECRET_PREFIX = "cyi_"
      SECRET_RANDOM_LENGTH = 40   # alphanumeric → ~238 bit
      DISPLAY_PREFIX_LENGTH = 12  # "cyi_" + 8 char mostrati in chiaro

      # Default: bearer cyi_ SERVER-ONLY a piena potenza (ingest + read) — vedi CYRA-37 /
      # decisions/2026-07-09-cyi-token-server-only. Passare scopes: ["ingest"] per un token ristretto.
      # expires_at nil = credenziale senza scadenza (CYRA-716): resta il default perché imporne una a
      # tutti spegnerebbe l'ingest di chi non se l'aspetta. Una data nel passato non passa la
      # validazione del modello e torna R422-TOKEN-001 come ogni altro campo invalido.
      def initialize(project:, name:, host:, environment:, created_by: nil, scopes: [ "ingest", "read" ],
                     expires_at: nil)
        @project = project
        @name = name
        @host = host
        @environment = environment
        @created_by = created_by
        @scopes = scopes
        @expires_at = expires_at
      end

      def call
        secret = "#{SECRET_PREFIX}#{SecureRandom.alphanumeric(SECRET_RANDOM_LENGTH)}"
        public_key = SecureRandom.hex(16)   # 32 hex, stile Sentry

        token = @project.tokens.create!(
          name: @name,
          environment: @environment,
          created_by: @created_by,
          token_digest: Digest::SHA256.hexdigest(secret),
          token_prefix: secret[0, DISPLAY_PREFIX_LENGTH],
          public_key: public_key,
          scopes: @scopes,
          expires_at: @expires_at
        )

        Result.ok({ token:, secret:, dsn: token.to_dsn(host: @host),
                    sentry_dsn: token.to_sentry_dsn(host: @host) })
      rescue ActiveRecord::RecordInvalid => e
        Result.err(AppError.new(e.message, code: "R422-TOKEN-001", details: e.record.errors.as_json))
      end
    end
  end
end
