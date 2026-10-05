# frozen_string_literal: true

module Secrets
  module Notifications
    # Notifica di sincronizzazione GitHub fallita (CYRA-138, Fase 4 pezzo B): evento di
    # PROGETTO/sistema, nessuna variabile coinvolta — subject = il progetto. Stessi destinatari di
    # rotazione/cancellazione (Alerting::Recipients.for_secrets). Nessun attore da escludere: non è
    # un'azione umana, è il job di sync che fallisce.
    #
    # Idempotenza: finestra per [progetto, GIORNO] — non per singolo tentativo né per causa. Ogni
    # Set/Delete/Import sul progetto (oltre a un eventuale "Sync now" manuale) enfila un NUOVO SyncJob
    # — un repo mal configurato può quindi rifallire molte volte nella stessa giornata (una per ogni
    # modifica ai secret), non per retry automatico di ApplicationJob (i fallimenti di dominio tornano
    # come Result.err, mai un'eccezione: retry_on non si attiva). Tutti questi tentativi condividono la
    # STESSA dedup_key (project_id + data odierna) → UNA sola notifica per progetto al giorno finché il
    # sync non torna a funzionare. Scelta deliberata (vedi ticket CYRA-138): niente scomposizione per
    # slot (production/staging/preview) né per causa/codice errore — Sync.call ritorna al PRIMO slot
    # che fallisce, quindi lo slot/causa può variare da un tentativo all'altro nella stessa giornata, e
    # frammentare la finestra per slot/causa produrrebbe più notifiche/giorno esattamente nel caso che
    # vogliamo evitare (spam). Il giorno successivo, se il sync fallisce ancora, la key cambia (nuova
    # data) → l'avviso si riarma da solo.
    class DispatchSyncFailed < ApplicationService
      def self.call(...) = new(...).call

      def initialize(project:, reason: nil, at: Time.current)
        @project = project
        @reason = reason
        @at = at
      end

      def call
        content = Content.for_sync_failure(project: @project, reason: @reason)
        delivered = 0
        Alerting::Recipients.for_secrets(project: @project).each do |account|
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
        channels = pref.channels_for(:secret_sync_failed, connected_telegram: account.connected_telegram?)

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
          event_type: :secret_sync_failed, content: content, dedup_key: dedup_key(account, "in_app")
        )
        result.ok? ? 1 : 0
      end

      def deliver_email(account, content, pref, decision)
        return 0 unless decision[:deliver]

        result = Deliver.email(
          account: account, subject: @project, project: @project, organization: organization,
          event_type: :secret_sync_failed, content: content, dedup_key: dedup_key(account, "email"),
          quiet: pref.quiet_now?(at: @at), bucket: decision[:bucket]
        )
        result.ok? ? 1 : 0
      end

      # Torna il Result della consegna (nil se il canale è spento): serve a decidere la mail (CYRA-853).
      def deliver_telegram(account, content, decision)
        return unless decision[:deliver]

        Deliver.telegram(
          account: account, subject: @project, project: @project, organization: organization,
          event_type: :secret_sync_failed, content: content, dedup_key: dedup_key(account, "telegram"),
          bucket: decision[:bucket]
        )
      end

      # Per [progetto, giorno]: vedi commento di classe per il perché non slot/causa.
      def dedup_key(account, via)
        "secret_sync_failed:#{@project.id}:#{@at.to_date}:#{account.id}:#{via}"
      end
    end
  end
end
