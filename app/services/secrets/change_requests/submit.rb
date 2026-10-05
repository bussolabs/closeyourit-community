# frozen_string_literal: true

module Secrets
  module ChangeRequests
    # Punto UNICO di ingresso per le scritture web dei secret (CYRA-138, Fase 4 pezzo C1b —
    # INTERCETTAZIONE). Decide "applica subito o metti in attesa" chiedendo a Secrets::Approval se la
    # coppia [progetto, ambiente] è protetta dall'approvazione a due (fondamenta C1a). Instrada
    # set/promote/rollback/destroy del canale Member (Secrets::Rows::Save e i 3 controller); il canale
    # CLI resta invariato (C3) e Projects::Tokens::Provision (writer di sistema) NON passa mai di qui
    # (bypass voluto, come oggi).
    #
    # NON protetta → applica ESATTAMENTE come prima dell'intercettazione: delega a
    # Secrets::Variables::Set (action :set) o, per :remove, risolve la variabile in
    # [project, environment, name] e delega a Secrets::Variables::Delete. Un errore di validazione torna
    # il MEDESIMO Result.err del service delegato (stesso codice) — nessuna differenza di comportamento.
    # Una :remove su una variabile già assente è trattata come no-op idempotente (applied, nessun
    # errore): lo stato finale desiderato — il secret non esiste — è già quello vero.
    #
    # Protetta → NON applica nulla: congela l'intento in una Secrets::ChangeRequest pending (C1a). Il
    # valore reale del secret NON cambia; l'applicazione/approvazione della richiesta arriva in C2. Nessun
    # audit event/notifica qui (fuori scope C1b, vedi Secrets::RecordEvent/le notifiche di C2).
    #
    # Result: SEMPRE Result.ok(Submitted) sul percorso felice — mai un value grezzo Variable o
    # ChangeRequest a seconda del ramo — così un chiamante controlla `result.value.applied?`/`.pending?`
    # senza dover indovinare il tipo. Result.err quando la scrittura o la richiesta falliscono.
    class Submit < ApplicationService
      # applied: la scrittura è stata eseguita subito (variable popolata, change_request nil).
      # !applied (pending): è nata una ChangeRequest pending e il secret NON è cambiato (change_request
      # popolata, variable nil).
      Submitted = Data.define(:applied, :variable, :change_request) do
        def applied? = applied
        def pending? = !applied
      end

      # enqueue_sync/audit: passthrough a Secrets::Variables::Set per l'azione :set applicata subito.
      # Default true (comportamento odierno di Set/dei controller); Secrets::Rows::Save passa enqueue_sync
      # false per un solo enqueue dopo il commit della riga, Secrets::Variables::Import passa entrambi
      # false per registrare UN solo evento "imported" aggregato invece di N eventi "set" per-voce
      # (CYRA-230). Sul ramo protetto (change request pending) non toccano nulla: nessuna scrittura.
      def initialize(project:, environment:, name:, action:, actor:, value: nil, description: nil,
                     source_version: nil, enqueue_sync: true, audit: true, description_only: false)
        @project = project
        @environment = environment
        @name = name.to_s.strip.upcase
        @action = action.to_s
        @actor = actor
        @value = value
        @description = description
        @description_only = description_only
        @source_version = source_version
        @enqueue_sync = enqueue_sync
        @audit = audit
      end

      def call
        if ::Secrets::Approval.required?(project: @project, environment: @environment)
          submit_for_approval
        else
          apply_now
        end
      end

      private

      def set_action? = @action == "set"

      def apply_now
        set_action? ? apply_set : apply_remove
      end

      def apply_set
        service = @description_only ? ::Secrets::Variables::UpdateDescription : ::Secrets::Variables::Set
        attributes = @description_only ? {} : { value: @value }
        result = service.call(
          project: @project, environment: @environment, name: @name, **attributes,
          description: @description, actor: @actor, enqueue_sync: @enqueue_sync, audit: @audit
        )
        return result if result.err?

        Result.ok(Submitted.new(applied: true, variable: result.value, change_request: nil))
      end

      def apply_remove
        variable = @project.secret_variables.find_by(environment: @environment, name: @name)
        return Result.ok(Submitted.new(applied: true, variable: nil, change_request: nil)) if variable.nil?

        result = ::Secrets::Variables::Delete.call(variable:, actor: @actor)
        return result if result.err?

        Result.ok(Submitted.new(applied: true, variable: result.value, change_request: nil))
      end

      def submit_for_approval
        return description_unavailable if unsupported_description_change?

        description_attributes = if ::Secrets::ChangeRequest.description_requests_supported? && set_action?
          { description: @description, description_only: @description_only }
        else
          {}
        end
        change_request = ::Secrets::ChangeRequest.create!(
          project: @project, environment: @environment, organization: @project.organization,
          name: @name, action: @action, value: (set_action? ? @value : nil),
          requested_by: @actor, source_version: @source_version, status: :pending, **description_attributes
        )
        enqueue_change_request_notification(change_request, event: "requested")
        Result.ok(Submitted.new(applied: false, variable: nil, change_request:))
      rescue ActiveRecord::RecordInvalid => e
        Result.err(AppError.new(e.message, code: "R422-SECRET-004", details: e.record.errors.as_json))
      end

      def unsupported_description_change?
        return false if ::Secrets::ChangeRequest.description_requests_supported?
        return true if @description_only
        return false if @description.nil? || !set_action?

        current = @project.secret_variables.find_by(environment: @environment, name: @name)
        current&.description.to_s != @description.to_s.strip
      end

      def description_unavailable
        Result.err(AppError.new(I18n.t("member.review_fixes.secret_protected_description"), code: "R422-SECRET-004"))
      end

      # Notifica agli approvatori (CYRA-138, Fase 4 pezzo C2c): ESPLICITA subito dopo il create!, mai
      # after_commit (Solid Queue è su un DB separato, non partecipa alla transazione — vedi
      # Secrets::Notifications::ChangeRequestNotifyJob). Submit può girare dentro la transazione di
      # Secrets::Rows::Save: se la riga fa rollback dopo, il job trova la CR assente e resta un no-op.
      def enqueue_change_request_notification(change_request, event:)
        ::Secrets::Notifications::ChangeRequestNotifyJob.perform_later(
          change_request_id: change_request.id, event: event
        )
      end
    end
  end
end
