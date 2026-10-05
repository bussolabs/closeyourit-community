# frozen_string_literal: true

module Ticketing
  module Notifications
    # Notifica un nuovo commento ai watcher del ticket: chi è menzionato (@handle) riceve una notifica
    # "mentioned", gli altri watcher una "commented" (un menzionato NON riceve anche il commented).
    # Esclude SEMPRE l'autore. Idempotente (dedup_key per commento+account+canale). Rispetta le
    # preferenze (tickets_enabled, canali, quiet hours). Twin di DispatchEvent per il path commenti.
    class DispatchComment < ApplicationService
      def self.call(...) = new(...).call

      def initialize(comment:, mentioned_ids: [], at: Time.current)
        @comment = comment
        @mentioned_ids = Array(mentioned_ids).map(&:to_s).to_set
        @at = at
      end

      def call
        ticket = @comment.ticket
        return Result.ok(0) if ticket.nil?

        organization = ticket.project.organization
        delivered = 0
        ticket.subscribers.to_a.each do |account|
          next if account.id == @comment.author_id

          event_type = @mentioned_ids.include?(account.id.to_s) ? :ticket_mentioned : :ticket_commented
          delivered += deliver_to(account, ticket, organization, event_type)
        end
        Result.ok(delivered)
      end

      private

      def deliver_to(account, ticket, organization, event_type)
        pref = Alerting::Preference.for(account: account, organization: organization)
        channels = pref.channels_for(event_type, connected_telegram: account.connected_telegram?)

        # Content snapshottato nella lingua del destinatario (title/body finiscono congelati nella riga).
        content = I18n.with_locale(account.effective_locale) { content_for(event_type, ticket) }
        count = 0
        count += deliver_in_app(account, ticket, organization, event_type, content) # in-app SEMPRE
        telegram = deliver_telegram(account, ticket, organization, event_type, content, channels[:telegram])
        unless ::Notifications::Deliver.reached_by_telegram?(telegram)
          count += deliver_email(account, ticket, organization, event_type, content, pref, channels[:email])
        end
        count + (telegram&.ok? ? 1 : 0)
      end

      def deliver_in_app(account, ticket, organization, event_type, content)
        result = Deliver.in_app(
          account: account, ticket: ticket, organization: organization,
          event_type: event_type, content: content, dedup_key: dedup_key(account, "in_app")
        )
        result.ok? ? 1 : 0
      end

      def deliver_email(account, ticket, organization, event_type, content, pref, decision)
        return 0 unless decision[:deliver]

        result = Deliver.email(
          account: account, ticket: ticket, organization: organization,
          event_type: event_type, content: content, dedup_key: dedup_key(account, "email"),
          quiet: pref.quiet_now?(at: @at), bucket: decision[:bucket]
        )
        result.ok? ? 1 : 0
      end

      # Torna il Result della consegna (nil se il canale è spento): serve a decidere la mail (CYRA-853).
      def deliver_telegram(account, ticket, organization, event_type, content, decision)
        return unless decision[:deliver]

        Deliver.telegram(
          account: account, ticket: ticket, organization: organization,
          event_type: event_type, content: content, dedup_key: dedup_key(account, "telegram"),
          bucket: decision[:bucket]
        )
      end

      # Il titolo dipende dal destinatario (menzionato vs semplice watcher); il corpo è l'estratto
      # del commento. Riusa la struct Ticketing::Notifications::Content.
      def content_for(event_type, ticket)
        key = event_type == :ticket_mentioned ? "mentioned" : "commented"
        Content.new(
          title: I18n.t("ticketing.notifications.content.#{key}", code: ticket.code, name: @comment.author&.name),
          body: @comment.body.to_s.truncate(140),
          url: Rails.application.routes.url_helpers.member_ticket_path(ticket)
        )
      end

      def dedup_key(account, via)
        "comment:#{@comment.id}:#{account.id}:#{via}"
      end
    end
  end
end
