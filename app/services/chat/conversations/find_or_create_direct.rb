# frozen_string_literal: true

module Chat
  module Conversations
    # Trova o crea il DM 1:1 fra due membri della stessa org. Gating: entrambi membri E con almeno un
    # progetto visibile in comune (CommonScope). Idempotente via direct_key canonica; crea le 2 righe
    # Chat::Participant (che per i DM sono anche l'ACL). Result pattern.
    class FindOrCreateDirect < ApplicationService
      def initialize(organization:, account_a:, account_b:, actor: nil)
        @organization = organization
        @account_a = account_a
        @account_b = account_b
        @actor = actor || account_a
      end

      def call
        return Result.err(error("same_account", "R422-CHAT-001")) if @account_a.id == @account_b.id

        # Una DM già esistente si RITROVA senza rivalidare il gate (che vale solo per crearne una
        # nuova): due persone con cronologia restano in contatto anche se nel frattempo non
        # condividono più alcun progetto — la conversazione è comunque loro (ACL = partecipanti).
        existing = find_existing
        if existing
          ensure_participants(existing)
          return Result.ok(existing)
        end

        return Result.err(error("not_member", "R422-CHAT-002")) unless both_members?
        return Result.err(error("no_shared_project", "R403-CHAT-003", :forbidden)) unless shared_project?

        conversation = find_or_create
        return Result.err(invalid(conversation)) unless conversation&.persisted?

        ensure_participants(conversation)
        Result.ok(conversation)
      end

      private

      def direct_key
        Chat::Conversation.direct_key_for(@account_a, @account_b)
      end

      def find_existing
        Chat::Conversation.find_by(organization: @organization, direct_key: direct_key)
      end

      def find_or_create
        Chat::Conversation.find_or_create_by(organization: @organization, direct_key: direct_key) do |conversation|
          conversation.kind = :direct
          conversation.created_by = @actor
        end
      rescue ActiveRecord::RecordNotUnique
        Chat::Conversation.find_by(organization: @organization, direct_key: direct_key)
      end

      def ensure_participants(conversation)
        Chat::Participant.ensure_for(conversation: conversation, account: @account_a)
        Chat::Participant.ensure_for(conversation: conversation, account: @account_b)
      end

      def both_members?
        # Una sola query invece di una exists? per account (loop bounded a 2, ma la fingerprint
        # ripetuta faceva scattare prosopite): entrambi membri ⇔ tante membership distinte quanti
        # gli account distinti coinvolti.
        account_ids = [ @account_a.id, @account_b.id ].uniq
        Connections::Membership.where(organization_id: @organization.id, account_id: account_ids)
                               .distinct.count(:account_id) == account_ids.size
      end

      def shared_project?
        Chat::CommonScope.new(accounts: [ @account_a, @account_b ], organization: @organization).any?
      end

      def error(key, code, status = :unprocessable_content)
        AppError.new(I18n.t("chat.errors.#{key}"), code: code, status: status)
      end

      def invalid(conversation)
        AppError.new(I18n.t("chat.errors.invalid_conversation"), code: "R422-CHAT-004",
                     details: conversation&.errors&.to_hash)
      end
    end
  end
end
