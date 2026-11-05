# frozen_string_literal: true

module Ticketing
  module StalledEpics
    # Sends the stalled-epic notice to whoever has to act and to the epic's assignee: in-app always,
    # Telegram or email when ticket notices are on. The fingerprint is in the dedup key, so the same
    # situation is never sent twice and a changed one is (CYRA-1155).
    class Notify < ApplicationService
      EVENT_TYPE = :ticket_epic_stalled

      def initialize(stall:)
        @stall = stall
        @epic = stall.epic
        @organization = @epic.project.organization
      end

      def call
        Result.ok(recipients.sum { |account| deliver_to(account) })
      end

      private

      # Only current members: someone who left the organization hears no more about its epics.
      def recipients
        accounts = (@stall.waits.map(&:account) + [ @epic.assignee ]).compact.uniq
        members = Connections::Membership.where(organization_id: @organization.id, account_id: accounts.map(&:id))
                                         .pluck(:account_id).to_set
        accounts.select { |account| members.include?(account.id) }
      end

      def deliver_to(account)
        preference = Alerting::Preference.for(account:, organization: @organization)
        content = I18n.with_locale(account.effective_locale) { Ticketing::Notifications::Content.stalled_epic(stall: @stall) }
        args = { account:, ticket: @epic, organization: @organization, event_type: EVENT_TYPE, content: }

        count = Ticketing::Notifications::Deliver.in_app(**args, dedup_key: dedup_key(account, "in_app")).ok? ? 1 : 0
        return count unless preference.source_enabled?(EVENT_TYPE)

        channels = preference.channels_for(EVENT_TYPE, connected_telegram: account.connected_telegram?)
        telegram = deliver_telegram(args, account, channels[:telegram])
        count += 1 if telegram&.ok?
        return count if ::Notifications::Deliver.reached_by_telegram?(telegram) || !channels[:email][:deliver]

        email = Ticketing::Notifications::Deliver.email(**args, dedup_key: dedup_key(account, "email"),
                                                                quiet: preference.quiet_now?, bucket: channels[:email][:bucket])
        count + (email.ok? ? 1 : 0)
      end

      def deliver_telegram(args, account, decision)
        return unless decision[:deliver]

        Ticketing::Notifications::Deliver.telegram(**args, dedup_key: dedup_key(account, "telegram"), bucket: decision[:bucket])
      end

      def dedup_key(account, via) = "epic_stalled:#{@epic.id}:#{@stall.fingerprint}:#{account.id}:#{via}"
    end
  end
end
