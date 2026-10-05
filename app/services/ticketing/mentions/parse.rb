# frozen_string_literal: true

module Ticketing
  module Mentions
    # Estrae gli account menzionati (@handle) in un testo, RISTRETTI ai membri dell'org indicata
    # (anti-leak: la @menzione di un non-membro non risolve). Case-insensitive, deduplicato. Il
    # lookbehind evita i falsi positivi sugli indirizzi email (foo@bar non è una menzione). Il
    # chiamante sottrae l'autore (no self-mention). Ritorna un Array<Account> (helper, non Result).
    class Parse < ApplicationService
      def self.call(...) = new(...).call

      # @ a inizio token (non preceduto da word-char o punto) + handle [a-z0-9_].
      MENTION = /(?<![\w.])@([a-z0-9_]+)/i

      def initialize(text:, organization:)
        @text = text.to_s
        @organization = organization
      end

      def call
        handles = @text.scan(MENTION).flatten.map(&:downcase).uniq
        return [] if handles.empty?

        member_ids = Connections::Membership.where(organization_id: @organization.id).select(:account_id)
        Accounts::Account.where(handle: handles).where(id: member_ids).to_a
      end
    end
  end
end
