# frozen_string_literal: true

module Secrets
  module Personal
    module Variables
      # Crea o aggiorna (upsert) una variabile del vault personale per [account, organization, nome]. Il nome
      # è normalizzato UPPER_SNAKE; il valore è cifrato at-rest dal model (encrypts :value). La logica di
      # scrittura vive qui (mai in callback), consumata identica da Member web e Cli::V1. Nessun sync GitHub.
      class Set < ApplicationService
        # audit: false quando chiamato in bulk da Import (che registra l'evento "imported" UNA volta dopo
        # la transazione — evita N eventi per-voce).
        def initialize(account:, organization:, name:, value:, description: nil, audit: true)
          @account = account
          @organization = organization
          @name = name.to_s.strip.upcase
          @value = value.to_s
          @description = description
          @audit = audit
        end

        def call
          variable = Secrets::Personal::Variable
                     .for(account: @account, organization: @organization)
                     .find_or_initialize_by(name: @name)
          # Su record NUOVO aggancia gli oggetti già caricati (stesso id dello scope): la validazione
          # presence dei belongs_to li usa dalla memoria invece di ri-interrogare accounts/organizations
          # (anti N+1 nel loop di Import, che importa solo nomi nuovi). Su record esistente NON si tocca
          # (attr_readonly bloccherebbe il setter FK).
          if variable.new_record?
            variable.account = @account
            variable.organization = @organization
          end
          value_changed = new_plaintext?(variable)
          variable.value = @value
          variable.description = @description unless @description.nil?

          variable.save!
          Secrets::Personal::Versions::Snapshot.call(variable:) if value_changed
          record_set_event(variable) if @audit
          Result.ok(variable)
        rescue ActiveRecord::RecordInvalid => e
          Result.err(AppError.new(e.message, code: "R422-PERSONALSECRET-001", details: e.record.errors.as_json))
        end

        private

        # True se il PLAINTEXT cambia (nuovo record, o valore diverso). NON si confronta il ciphertext:
        # la cifratura non-deterministica dà un ciphertext diverso ad ogni save anche a parità di valore.
        def new_plaintext?(variable)
          variable.new_record? || variable.value != @value
        end

        def record_set_event(variable)
          Secrets::Personal::RecordEvent.call(action: "set", account: @account,
                                              organization: @organization, name: variable.name)
        end
      end
    end
  end
end
