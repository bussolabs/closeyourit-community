# frozen_string_literal: true

module Secrets
  module Notifications
    # Notifica di richiesta RIFIUTATA (CYRA-138, Fase 4 pezzo C2c): gemella di DispatchChangeApproved,
    # destinatario UNICO = il richiedente (Secrets::ChangeRequests::Reject l'ha appena decisa) — il
    # valore reale del secret non è cambiato, ma il richiedente deve sapere che la sua proposta non è
    # passata e perché (reason nel corpo). Richiedente non risolvibile (account cancellato) → no-op
    # silenzioso, mai un errore.
    #
    # Subject = il progetto. Idempotenza: una CR passa per rejected UNA sola volta (guard stale), il
    # dedup_key ancorato a change_request.id basta.
    class DispatchChangeRejected < ApplicationService
      def self.call(...) = new(...).call

      def initialize(change_request:, at: Time.current)
        @change_request = change_request
        @project = change_request.project
        @at = at
      end

      def call
        account = @change_request.requested_by
        return Result.ok(0) if account.nil?

        content = Content.for_change_rejected(change_request: @change_request)
        Result.ok(deliver_to(account, content))
      end

      private

      def organization
        @organization ||= @project.organization
      end

      def deliver_to(account, content)
        pref = Alerting::Preference.for(account: account, organization: organization)
        channels = pref.channels_for(:secret_change_rejected, connected_telegram: account.connected_telegram?)

        count = 0
        count += deliver_in_app(account, content) # in-app SEMPRE
        telegram = deliver_telegram(account, content, channels[:telegram])
        unless ::Notifications::Deliver.reached_by_telegram?(telegram)
          count += deliver_email(account, content, pref, channels[:email])
        end
        count + (telegram&.ok? ? 1 : 0)
      end

      def deliver_in_app(account, content)
        result = Deliver.in_app(
          account: account, subject: @project, project: @project, organization: organization,
          event_type: :secret_change_rejected, content: content, dedup_key: dedup_key(account, "in_app")
        )
        result.ok? ? 1 : 0
      end

      def deliver_email(account, content, pref, decision)
        return 0 unless decision[:deliver]

        result = Deliver.email(
          account: account, subject: @project, project: @project, organization: organization,
          event_type: :secret_change_rejected, content: content, dedup_key: dedup_key(account, "email"),
          quiet: pref.quiet_now?(at: @at), bucket: decision[:bucket]
        )
        result.ok? ? 1 : 0
      end

      # Torna il Result della consegna (nil se il canale è spento): serve a decidere la mail (CYRA-853).
      def deliver_telegram(account, content, decision)
        return unless decision[:deliver]

        Deliver.telegram(
          account: account, subject: @project, project: @project, organization: organization,
          event_type: :secret_change_rejected, content: content, dedup_key: dedup_key(account, "telegram"),
          bucket: decision[:bucket]
        )
      end

      def dedup_key(account, via)
        "secret_change_rejected:#{@change_request.id}:#{account.id}:#{via}"
      end
    end
  end
end
