# frozen_string_literal: true

module Secrets
  module Github
    # Spinge i secret del vault sui GitHub Environment secrets del repo connesso. Per ogni slot mappato
    # (production/staging → Types::Environment su Github::Repository), cifra i valori sealed-box con la
    # public key dell'environment e li PUTa; poi cancella SOLO i nomi che il vault aveva già sincronizzato
    # per quello slot e che ora non ci sono più (delete-only-managed: MAI i secret impostati a mano, es.
    # KAMAL_*). I nomi sono già garantiti validi (vincolo GITHUB_/UPPER_SNAKE sul model Secrets::Variable).
    class Sync < ApplicationService
      def initialize(repository:, client: ::Github::Client.new)
        @repository = repository
        @client = client
      end

      def call
        preflight = ::Secrets::Github::Preflight.call(repository: @repository, client: @client)
        return record_failure(preflight.error) if preflight.err?

        installation_id = @repository.installation.installation_id

        # CYRA-637 — gli ambienti scritti stanno nell'esito e nell'evento accanto ai numeri: due
        # conteggi da soli non dicono DOVE sono finiti, e «riuscita» su metà lavoro si leggeva
        # identica a «riuscita» su tutto.
        summary = { pushed: 0, deleted: 0, environments: preflight.value.map(&:name) }
        preflight.value.each do |prepared_slot|
          slot_result = sync_slot(installation_id, prepared_slot, summary)
          return slot_result if slot_result.err?
        rescue ::Github::Client::Error => e
          return record_failure(transport_error(e), slot: prepared_slot.name)
        end

        ::Secrets::RecordEvent.call(action: "synced", project: @repository.project, metadata: summary)
        @repository.record_sync_success!
        Result.ok(summary)
      rescue ::Github::Client::Error => e
        record_failure(transport_error(e))
      end

      private

      # CYRA-106 — l'esito resta scritto sul repository: il job che chiama questo service è
      # fire-and-forget, quindi un Result.err che nessuno persiste è un fallimento che nessuno vede.
      # Il Result ritorna invariato: chi chiamava prima continua a leggere lo stesso errore.
      def record_failure(error, slot: nil)
        @repository.record_sync_failure!(error, slot:)
        Result.err(error)
      end

      def transport_error(error) = AppError.new(error.message, code: error.code, status: error.status)

      def sync_slot(installation_id, prepared_slot, summary)
        repository_id = @repository.repo_id
        env_name = prepared_slot.name
        bundle = prepared_slot.bundle
        if prepared_slot.secrets_json
          bundle = bundle.merge(::Secrets::Github::SecretsJson::SECRET_NAME => prepared_slot.secrets_json)
        end

        # Delete-only-managed: solo i nomi già sincronizzati dal vault e ora spariti.
        previously = Array(@repository.synced_secret_names[env_name])
        (previously - bundle.keys).each do |name|
          @client.delete_environment_secret(installation_id, repository_id, env_name, name)
          summary[:deleted] += 1
        end

        if bundle.any?
          public_key = @client.environment_public_key(installation_id, repository_id, env_name)
          bundle.each do |name, value|
            encrypted = ::Secrets::Github::Encryptor.call(public_key_base64: public_key.fetch("key"), value:).value
            @client.put_environment_secret(installation_id, repository_id, env_name, name,
                                           encrypted_value: encrypted, key_id: public_key.fetch("key_id"))
            summary[:pushed] += 1
          end
        end

        # Aggiorna la traccia dei nomi gestiti (per il prossimo delete-only-managed).
        tracked = @repository.synced_secret_names.merge(env_name => bundle.keys)
        @repository.update_column(:synced_secret_names, tracked)
        Result.ok(nil)
      end
    end
  end
end
