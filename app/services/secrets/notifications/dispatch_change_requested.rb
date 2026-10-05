# frozen_string_literal: true

module Secrets
  module Notifications
    # Notifica di richiesta di modifica in attesa di approvazione (CYRA-138, Fase 4 pezzo C2c): nasce
    # quando Secrets::ChangeRequests::Submit congela l'intento su una coppia [progetto, ambiente]
    # protetta. Destinatari = chi PUÒ decidere (Alerting::Recipients.for_secrets: owner + chi ha
    # secrets.manage sul progetto), ESCLUSO il richiedente — è lui/lei che deve aspettare una decisione
    # altrui, non ha senso ricordargli la propria richiesta appena fatta. Subject = il progetto (come
    # gli altri secret_*, mai la ChangeRequest: il progetto sopravvive a qualunque evoluzione della
    # richiesta).
    #
    # Idempotenza: dedup_key ancorata a change_request.id — una CR nasce una volta sola (Submit la crea
    # in un create! unico), quindi basta la difesa contro il retry di ApplicationJob.
    class DispatchChangeRequested < ApplicationService
      def self.call(...) = new(...).call

      def initialize(change_request:, at: Time.current)
        @change_request = change_request
        @project = change_request.project
        @at = at
      end

      def call
        content = Content.for_change_requested(change_request: @change_request)
        delivered = 0
        Alerting::Recipients.for_secrets(project: @project).each do |account|
          next if account.id == @change_request.requested_by_id

          delivered += deliver_to(account, content)
        end
        Result.ok(delivered)
      end

      private

      def organization
        @organization ||= @project.organization
      end

      def deliver_to(account, content)
        pref = Alerting::Preference.for(account: account, organization: organization)
        channels = pref.channels_for(:secret_change_requested, connected_telegram: account.connected_telegram?)

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
          event_type: :secret_change_requested, content: content, dedup_key: dedup_key(account, "in_app")
        )
        result.ok? ? 1 : 0
      end

      def deliver_email(account, content, pref, decision)
        return 0 unless decision[:deliver]

        result = Deliver.email(
          account: account, subject: @project, project: @project, organization: organization,
          event_type: :secret_change_requested, content: content, dedup_key: dedup_key(account, "email"),
          quiet: pref.quiet_now?(at: @at), bucket: decision[:bucket]
        )
        result.ok? ? 1 : 0
      end

      # Torna il Result della consegna (nil se il canale è spento): serve a decidere la mail (CYRA-853).
      def deliver_telegram(account, content, decision)
        return unless decision[:deliver]

        Deliver.telegram(
          account: account, subject: @project, project: @project, organization: organization,
          event_type: :secret_change_requested, content: content, dedup_key: dedup_key(account, "telegram"),
          bucket: decision[:bucket]
        )
      end

      def dedup_key(account, via)
        "secret_change_requested:#{@change_request.id}:#{account.id}:#{via}"
      end
    end
  end
end
