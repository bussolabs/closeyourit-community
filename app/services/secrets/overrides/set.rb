# frozen_string_literal: true

module Secrets
  module Overrides
    # Assegna (crea o aggiorna) l'override personale di un secret per una persona (CYRA-79). Unico
    # punto di scrittura, come Secrets::Variables::Set per i default: qui vivono il vincolo sul
    # destinatario e l'audit, così il canale web e un domani quello CLI non possono divergere.
    #
    # Due cose che NON fa, di proposito:
    #   * non enfila MAI il sync GitHub — un override non esce verso una macchina (vedi Secrets::Bundle);
    #   * non crea versioni né tocca `rotated_at` della variabile di progetto: lo storico e le policy di
    #     rotazione restano attaccati al default, che l'override non modifica.
    class Set < ApplicationService
      def initialize(project:, environment:, account:, name:, value:, description: nil, actor: nil)
        @project = project
        @environment = environment
        @account = account
        @name = name.to_s.strip.upcase
        # Come per le variabili: nil è un input assente (rifiutato dal model), "" è un valore esplicito
        # valido per le opzioni che devono esistere ma possono restare vuote.
        @value = value.nil? ? nil : value.to_s
        @description = description
        @actor = actor
      end

      def call
        return Result.err(recipient_error) unless recipient_allowed?

        override = ::Secrets::Override.find_or_initialize_by(
          project: @project, environment: @environment, account: @account, name: @name
        )
        override.organization = @project.organization if override.new_record?
        override.value = @value
        override.description = @description unless @description.nil?
        override.created_by ||= @actor

        override.save!
        record_event(override)
        Result.ok(override)
      rescue ActiveRecord::RecordInvalid => e
        Result.err(AppError.new(e.message, code: "R422-SECRET-005", details: e.record.errors.as_json))
      end

      private

      # Il destinatario dev'essere una delle persone che quei secret li possono già LEGGERE: assegnare
      # un valore personale a chi non ha accesso al vault del progetto non gli darebbe comunque nulla
      # (il bundle è dietro il gate secrets.read) e lascerebbe in giro una riga che sembra attiva.
      # Stessa lista mostrata dal pannello «Chi può vedere questi segreti».
      def recipient_allowed?
        return false if @account.nil?

        ::Secrets::Readers.for_project(@project).any? { |reader| reader.account.id == @account.id }
      end

      def recipient_error
        AppError.new("destinatario non abilitato a leggere i secret di questo progetto",
                     code: "R422-SECRET-006")
      end

      # `name` è il nome del secret, `metadata.target_account_id` DI CHI riceve l'override: l'attore
      # dell'evento resta chi l'ha assegnato, altrimenti nel registro sembrerebbe che sia stato il
      # destinatario a darselo da sé.
      def record_event(override)
        ::Secrets::RecordEvent.call(action: "override_set", project: @project, environment: @environment,
                                    actor: @actor, name: override.name,
                                    metadata: { target_account_id: override.account_id })
      end
    end
  end
end
