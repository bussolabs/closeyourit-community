# frozen_string_literal: true

module Secrets
  module Notifications
    # «Valore in comune» (CYRA-777): avvisa chi tiene i secret dell'organizzazione che una proposta di
    # consolidamento è nata. Gemello strutturale di DispatchRotationDue — rule_id nil, in-app SEMPRE
    # consegnata, email e Telegram secondo le preferenze — con due differenze che vengono dalla natura
    # della cosa: il subject è la PROPOSTA (org-scoped, nessun progetto: un valore in comune per
    # definizione non appartiene a un progetto solo) e i destinatari sono chi ha shared_secrets.manage,
    # non chi gestisce i segreti di un progetto — quelli non potrebbero accettarla.
    #
    # UNA volta per proposta: il dedup_key è ancorato all'id della proposta, che è unica per
    # [organizzazione, ambiente, valore]. Il giro giornaliero ripassa sulle stesse proposte aperte
    # ogni notte e non deve avvisare nessuno una seconda volta.
    class DispatchConsolidationSuggested < ApplicationService
      def self.call(...) = new(...).call

      def initialize(suggestion:, at: Time.current)
        @suggestion = suggestion
        @at = at
      end

      def call
        # Guardia difensiva: una proposta archiviata o già accettata non ha niente da chiedere. Il
        # chiamante avvisa solo alla nascita, ma il dispatch resta sicuro anche invocato a mano.
        return Result.ok(0) unless @suggestion.status_open?

        content = Content.for_consolidation(suggestion: @suggestion)
        delivered = 0
        Alerting::Recipients.for_shared_secrets(organization: organization).each do |account|
          delivered += deliver_to(account, content)
        end
        Result.ok(delivered)
      end

      private

      def organization = @suggestion.organization

      def deliver_to(account, content)
        pref = Alerting::Preference.for(account: account, organization: organization)
        channels = pref.channels_for(:secret_consolidation_suggested, connected_telegram: account.connected_telegram?)

        count = 0
        count += deliver_in_app(account, content)
        telegram = deliver_telegram(account, content, channels[:telegram])
        unless ::Notifications::Deliver.reached_by_telegram?(telegram)
          count += deliver_email(account, content, pref, channels[:email])
        end
        count + (telegram&.ok? ? 1 : 0)
      end

      def deliver_in_app(account, content)
        result = Deliver.in_app(
          account: account, subject: @suggestion, organization: organization,
          event_type: :secret_consolidation_suggested, content: content, dedup_key: dedup_key(account, "in_app")
        )
        result.ok? ? 1 : 0
      end

      def deliver_email(account, content, pref, decision)
        return 0 unless decision[:deliver]

        result = Deliver.email(
          account: account, subject: @suggestion, organization: organization,
          event_type: :secret_consolidation_suggested, content: content, dedup_key: dedup_key(account, "email"),
          quiet: pref.quiet_now?(at: @at), bucket: decision[:bucket]
        )
        result.ok? ? 1 : 0
      end

      # Torna il Result della consegna (nil se il canale è spento): serve a decidere la mail (CYRA-853).
      def deliver_telegram(account, content, decision)
        return unless decision[:deliver]

        Deliver.telegram(
          account: account, subject: @suggestion, organization: organization,
          event_type: :secret_consolidation_suggested, content: content, dedup_key: dedup_key(account, "telegram"),
          bucket: decision[:bucket]
        )
      end

      def dedup_key(account, via)
        "secret_consolidation:#{@suggestion.id}:#{account.id}:#{via}"
      end
    end
  end
end
