# frozen_string_literal: true

module Secrets
  module Variables
    # Crea o aggiorna (upsert) una variabile del vault per [progetto, ambiente, nome]. Il nome è
    # normalizzato UPPER_SNAKE; il valore è cifrato at-rest dal model (encrypts :value). La logica di
    # scrittura vive qui (mai in callback), consumata identica da Member web e Cli::V1.
    #
    # Rotazione (CYRA-138): `rotated_at` si aggiorna nello STESSO punto e con la STESSA condizione di
    # Versions::Snapshot (`value_changed`) — creazione o valore realmente diverso. Un cambio di sola
    # description, o un "set" col valore identico, non ri-arma la scadenza.
    class Set < ApplicationService
      include Secrets::Github::Syncable

      # enqueue_sync/audit: false quando chiamato in bulk da Import (che enfila il sync e registra
      # l'evento "imported" UNA volta dopo la transazione — evita N enqueue/N eventi per-voce).
      def initialize(project:, environment:, name:, value:, description: nil, actor: nil, enqueue_sync: true, audit: true)
        @project = project
        @environment = environment
        @name = name.to_s.strip.upcase
        # Non appiattire nil e stringa vuota: il primo è un input assente e viene rifiutato dal model,
        # la seconda è un valore esplicito valido per configurazioni opzionali.
        @value = value.nil? ? nil : value.to_s
        @description = description
        @actor = actor
        @enqueue_sync = enqueue_sync
        @audit = audit
      end

      def call
        variable = @project.secret_variables.find_or_initialize_by(environment: @environment, name: @name)
        variable.organization = @project.organization if variable.new_record?
        value_changed = new_plaintext?(variable)
        # CYRA-777: l'impronta di PRIMA, letta finché il record la porta ancora. Serve al giro mirato
        # sulle proposte: cambiare un valore può far nascere un «valore in comune» (la nuova impronta)
        # e insieme farne sparire uno (la vecchia), e chi guarda solo la nuova lascia in lista una
        # proposta su un valore che nessuno tiene più.
        previous_fingerprint = variable.value_fingerprint
        variable.value = @value
        variable.description = @description unless @description.nil?
        variable.created_by ||= @actor
        # Rotazione (CYRA-138): si "ri-arma" da sola riusando lo stesso segnale di Versions::Snapshot —
        # creazione o plaintext realmente cambiato. rotation_interval_days non è toccato qui (policy
        # impostata solo da Member::ProjectSecretsController#rotation).
        variable.rotated_at = Time.current if value_changed

        variable.save!
        ::Secrets::Versions::Snapshot.call(variable:, actor: @actor) if value_changed
        record_set_event(variable) if @audit
        enqueue_github_sync(@project) if @enqueue_sync
        enqueue_consolidation_refresh(variable, previous_fingerprint) if value_changed
        Result.ok(variable)
      rescue ActiveRecord::RecordInvalid => e
        Result.err(AppError.new(e.message, code: "R422-SECRET-001", details: e.record.errors.as_json))
      end

      private

      # True se il PLAINTEXT cambia (nuovo record, o valore diverso). NON si confronta il ciphertext:
      # la cifratura non-deterministica dà un ciphertext diverso ad ogni save anche a parità di valore.
      def new_plaintext?(variable)
        variable.new_record? || variable.value != @value
      end

      # Solo quando il valore è davvero cambiato: un salvataggio che non tocca il plaintext non può
      # cambiare nessun raggruppamento. Le impronte nulle (valore vuoto o troppo corto) si scartano —
      # `fingerprints: []` restringerebbe il giro a niente, non lo allargherebbe a tutto.
      def enqueue_consolidation_refresh(variable, previous_fingerprint)
        fingerprints = [ previous_fingerprint, variable.value_fingerprint ].compact.uniq
        return if fingerprints.empty?

        ::Secrets::Consolidation::RefreshJob.perform_later(
          organization_id: @project.organization_id, environment_id: @environment.id, fingerprints: fingerprints
        )
      end

      def record_set_event(variable)
        ::Secrets::RecordEvent.call(action: "set", project: @project, environment: @environment,
                                    actor: @actor, name: variable.name)
      end
    end
  end
end
