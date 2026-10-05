# frozen_string_literal: true

module Accounts
  module ApiTokens
    # Emette un token utente per la CLI (account-proxy). Genera il segreto bearer (mostrato UNA volta
    # nel Result) — in DB solo il digest SHA-256. Prefisso "cyi_u_" (distinto dai Projects::Token "cyi_").
    class Issue < ApplicationService
      SECRET_PREFIX = "cyi_u_"
      SECRET_RANDOM_LENGTH = 40    # alphanumeric → ~238 bit
      DISPLAY_PREFIX_LENGTH = 14   # "cyi_u_" (6) + 8 char mostrati in chiaro

      # Durata di default (CYRA-717): chi non dice niente ottiene un token a termine, non eterno.
      DEFAULT_LIFETIME = Accounts::Constants::API_TOKEN_DEFAULT_LIFETIME_DAYS.days

      # Sentinel: distingue "non ho espresso una scadenza" (→ default) da "voglio un token SENZA
      # scadenza" (expires_at: nil esplicito). Con un solo `nil` le due cose sarebbero la stessa, e
      # il default non potrebbe esistere senza togliere ai service account il token perpetuo.
      DEFAULT_EXPIRY = :default

      def initialize(account:, organization:, name:, expires_at: DEFAULT_EXPIRY)
        @account = account
        @organization = organization
        @name = name
        @expires_at = expires_at
      end

      def call
        return perpetual_not_allowed if perpetual? && !@account&.service?

        secret = "#{SECRET_PREFIX}#{SecureRandom.alphanumeric(SECRET_RANDOM_LENGTH)}"

        token = @account.api_tokens.create!(
          organization: @organization,
          name: @name,
          expires_at: resolved_expires_at,
          token_digest: Digest::SHA256.hexdigest(secret),
          token_prefix: secret[0, DISPLAY_PREFIX_LENGTH]
        )

        Result.ok({ token:, secret: })
      rescue ActiveRecord::RecordInvalid => e
        Result.err(AppError.new(e.message, code: "R422-CLIAUTH-001", details: e.record.errors.as_json))
      end

      private

      # Richiesta esplicita di un token senza scadenza.
      def perpetual? = @expires_at.nil?

      def resolved_expires_at
        return nil if perpetual?
        return DEFAULT_LIFETIME.from_now if @expires_at == DEFAULT_EXPIRY

        @expires_at
      end

      # Un token perpetuo è consentito ai soli account di SERVIZIO: sono identità non umane, senza
      # browser per rifare il device-flow, e le automazioni che li usano si fermerebbero da sole ogni
      # tre mesi. Per una persona, invece, il perpetuo è proprio ciò che il ticket toglie: rifiutare
      # è più onesto che concedere in silenzio una scadenza diversa da quella richiesta.
      def perpetual_not_allowed
        Result.err(AppError.new(
                     "Un token personale deve avere una scadenza",
                     code: "R422-CLIAUTH-002",
                     details: { expires_at: [ "richiesto per gli account personali" ] }
                   ))
      end
    end
  end
end
