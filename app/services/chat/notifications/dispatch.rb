# frozen_string_literal: true

module Chat
  module Notifications
    # Fan-out delle notifiche di un nuovo messaggio all'audience della conversazione (DM → l'altro;
    # canale progetto → chi vede il progetto; canale team → i membri). Esclude SEMPRE l'autore e chi ha
    # silenziato la conversazione. I menzionati (@handle, membri dell'org) ricevono `chat_mentioned`,
    # gli altri `chat_message`. Idempotente (dedup_key per messaggio+account+canale). Rispetta le
    # preferenze (chat_enabled, canali, quiet hours). Twin di Ticketing::Notifications::DispatchComment.
    class Dispatch < ApplicationService
      def self.call(...) = new(...).call

      def initialize(message:, at: Time.current)
        @message = message
        @conversation = message&.conversation
        @at = at
      end

      def call
        return Result.ok(0) if @message.nil? || @conversation.nil?

        organization = @conversation.organization
        audience = @conversation.audience
        mentioned = mentioned_ids
        muted = muted_account_ids
        members = member_ids(organization, audience)
        delivered = 0

        audience.each do |account|
          next if account.id == @message.author_id
          next if muted.include?(account.id)
          # Revoca live: un ex-membro dell'org (riga Membership rimossa) resta nell'audience dei DM via
          # Chat::Participant — non deve più ricevere notifiche (in-app né email) per quest'org.
          next unless members.include?(account.id)

          event_type = mentioned.include?(account.id) ? :chat_mentioned : :chat_message
          delivered += deliver_to(account, organization, event_type)
        end

        Result.ok(delivered)
      end

      private

      def mentioned_ids
        Ticketing::Mentions::Parse.call(text: @message.body.to_s, organization: @conversation.organization)
                                  .map(&:id).to_set
      end

      def muted_account_ids
        @conversation.participants.muted.pluck(:account_id).to_set
      end

      def member_ids(organization, audience)
        Connections::Membership
          .where(organization_id: organization.id, account_id: audience.map(&:id))
          .pluck(:account_id).to_set
      end

      def deliver_to(account, organization, event_type)
        pref = Alerting::Preference.for(account: account, organization: organization)
        channels = pref.channels_for(event_type, connected_telegram: account.connected_telegram?)

        # Content snapshottato nella lingua del destinatario (title/body finiscono congelati nella riga).
        content = I18n.with_locale(account.effective_locale) { content_for(event_type) }
        count = 0
        count += deliver_in_app(account, organization, event_type, content) # in-app SEMPRE
        telegram = deliver_telegram(account, organization, event_type, content, channels[:telegram])
        unless ::Notifications::Deliver.reached_by_telegram?(telegram)
          count += deliver_email(account, organization, event_type, content, pref, channels[:email])
        end
        count + (telegram&.ok? ? 1 : 0)
      end

      def deliver_in_app(account, organization, event_type, content)
        Deliver.in_app(
          account: account, message: @message, organization: organization,
          event_type: event_type, content: content, dedup_key: dedup_key(account, "in_app")
        ).ok? ? 1 : 0
      end

      def deliver_email(account, organization, event_type, content, pref, decision)
        return 0 unless decision[:deliver]

        Deliver.email(
          account: account, message: @message, organization: organization,
          event_type: event_type, content: content, dedup_key: dedup_key(account, "email"),
          quiet: pref.quiet_now?(at: @at), bucket: decision[:bucket]
        ).ok? ? 1 : 0
      end

      # Torna il Result della consegna (nil se il canale è spento): serve a decidere la mail (CYRA-853).
      def deliver_telegram(account, organization, event_type, content, decision)
        return unless decision[:deliver]

        Deliver.telegram(
          account: account, message: @message, organization: organization,
          event_type: event_type, content: content, dedup_key: dedup_key(account, "telegram"),
          bucket: decision[:bucket]
        )
      end

      # Titolo dipendente dal destinatario (menzionato vs messaggio semplice); corpo = estratto.
      def content_for(event_type)
        key = event_type == :chat_mentioned ? "mentioned" : "message"
        Content.new(
          title: I18n.t("chat.notifications.content.#{key}",
                        name: @message.author&.name, conversation: conversation_title),
          body: @message.body.to_s.truncate(140),
          url: Rails.application.routes.url_helpers.member_chat_conversation_path(@conversation)
        )
      end

      # Titolo neutro della conversazione (nome del contesto per i canali; per un DM il nome
      # dell'autore rende già il contesto → fallback al kind).
      def conversation_title
        @conversation.contextable&.name || I18n.t("member.chat.kinds.#{@conversation.kind}")
      end

      def dedup_key(account, via)
        "chat:#{@message.id}:#{account.id}:#{via}"
      end
    end
  end
end
