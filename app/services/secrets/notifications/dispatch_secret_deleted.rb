# frozen_string_literal: true

module Secrets
  module Notifications
    # Notifica di cancellazione di un secret (CYRA-138, Fase 4 pezzo B): la VARIABILE è già distrutta
    # quando questo dispatch gira (chiamato dal job, mai in-line nella richiesta) — il subject della
    # notifica è quindi il PROGETTO (sopravvive), non un Secrets::Variable. Stessi destinatari della
    # rotazione (Alerting::Recipients.for_secrets: owner + chi ha secrets.manage sul progetto), ma
    # ESCLUDE l'attore che ha cancellato — come le notifiche ticket (Ticketing::Notifications::DispatchEvent),
    # non ha senso auto-notificarsi di un'azione appena compiuta.
    #
    # Idempotenza: il dedup_key include `variable_id`, l'id della riga ORMAI DISTRUTTA. ActiveRecord
    # non svuota gli attributi in memoria dopo #destroy! — l'id resta leggibile — quindi il chiamante
    # (Secrets::Variables::Delete) lo cattura una volta sola e lo fa viaggiare (job → qui) IDENTICO sui
    # retry automatici di ApplicationJob (stesso argomento serializzato) → stessa dedup_key → niente
    # doppioni. Una cancellazione SUCCESSIVA, anche dello stesso nome (nuova riga, nuovo id per via
    # della PK generata dal DB), produce un variable_id diverso → nuova notifica: un delete è un evento
    # one-shot, mai raggruppato con un altro nel tempo.
    class DispatchSecretDeleted < ApplicationService
      def self.call(...) = new(...).call

      def initialize(project:, variable_id:, name:, environment_label:, actor: nil, at: Time.current)
        @project = project
        @variable_id = variable_id
        @name = name
        @environment_label = environment_label
        @actor = actor
        @at = at
      end

      def call
        content = Content.for_deletion(project: @project, name: @name, environment_label: @environment_label,
                                       actor: @actor)
        delivered = 0
        Alerting::Recipients.for_secrets(project: @project).each do |account|
          next if @actor && account.id == @actor.id

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
        channels = pref.channels_for(:secret_deleted, connected_telegram: account.connected_telegram?)

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
          event_type: :secret_deleted, content: content, dedup_key: dedup_key(account, "in_app")
        )
        result.ok? ? 1 : 0
      end

      def deliver_email(account, content, pref, decision)
        return 0 unless decision[:deliver]

        result = Deliver.email(
          account: account, subject: @project, project: @project, organization: organization,
          event_type: :secret_deleted, content: content, dedup_key: dedup_key(account, "email"),
          quiet: pref.quiet_now?(at: @at), bucket: decision[:bucket]
        )
        result.ok? ? 1 : 0
      end

      # Torna il Result della consegna (nil se il canale è spento): serve a decidere la mail (CYRA-853).
      def deliver_telegram(account, content, decision)
        return unless decision[:deliver]

        Deliver.telegram(
          account: account, subject: @project, project: @project, organization: organization,
          event_type: :secret_deleted, content: content, dedup_key: dedup_key(account, "telegram"),
          bucket: decision[:bucket]
        )
      end

      def dedup_key(account, via)
        "secret_deleted:#{@variable_id}:#{account.id}:#{via}"
      end
    end
  end
end
