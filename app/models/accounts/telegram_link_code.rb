# frozen_string_literal: true

module Accounts
  # Codice corto monouso del deep-link /start del bot Telegram. Rimpiazza il token firmato
  # (generates_token_for), che a 238 char non entra nel parametro `start` di Telegram (max 64,
  # solo [A-Za-z0-9_-]). Il codice è url-safe (32 char), scade, e viene consumato (single-use)
  # al collegamento. Vive nel primary DB (condiviso tra container, a differenza di Solid Cache).
  # Si salva solo lo SHA-256 del codice, come per AiGateway::Key: il codice in chiaro esiste solo nel
  # link mostrato alla persona (CYRA-1264). Casuale e lungo, non serve un hash lento.
  class TelegramLinkCode < ApplicationRecord
    # Il namespace Accounts non ha table_name_prefix (Accounts::Account → "accounts"); nome esplicito.
    self.table_name = "accounts_telegram_link_codes"

    belongs_to :account, class_name: "Accounts::Account"
    # Presente = il codice collega il gruppo con argomenti di questa organizzazione (CYRA-852).
    belongs_to :organization, class_name: "Organizations::Organization", optional: true

    # 24 byte → 32 char url-safe [A-Za-z0-9_-] senza padding: valido e ben sotto il limite Telegram (64).
    CODE_BYTES = 24

    scope :active, -> { where(expires_at: Time.current..) }

    def self.digest(code) = Digest::SHA256.hexdigest(code.to_s)

    # Conia un nuovo codice per l'account (purga i scaduti al volo, niente job dedicato) e restituisce
    # la stringa da mettere nel deep-link: è l'unica volta che esiste in chiaro. Regenera in caso di
    # collisione (improbabilissima).
    def self.issue(account:, organization: nil, ttl: Accounts::Constants::TTL_TELEGRAM_LINK)
      where(expires_at: ..Time.current).delete_all
      code = SecureRandom.urlsafe_base64(CODE_BYTES)
      create!(account: account, organization: organization, code_digest: digest(code), expires_at: ttl.from_now)
      code
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    # Risolve un codice attivo al suo account e lo consuma (single-use). nil se assente/scaduto/blank.
    def self.consume(code)
      take(active.where(organization_id: nil), code)&.account
    end

    # Come consume, ma solo per i codici di un gruppo: torna il codice consumato, con account e organizzazione.
    def self.consume_for_group(code)
      take(active.where.not(organization_id: nil), code)
    end

    def self.take(scope, code)
      return nil if code.blank?

      scope.includes(:account, :organization).find_by(code_digest: digest(code))&.destroy
    end
    private_class_method :take
  end
end
