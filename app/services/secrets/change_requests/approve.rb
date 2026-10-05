# frozen_string_literal: true

module Secrets
  module ChangeRequests
    # Approva una Secrets::ChangeRequest pending (CYRA-138, Fase 4 pezzo C2a — SERVICE DI DECISIONE):
    # applica DIRETTAMENTE la modifica chiamando Secrets::Variables::Set/Delete, bypassando
    # Secrets::ChangeRequests::Submit e il guard Secrets::Approval — se richiamasse Submit, una coppia
    # [progetto, ambiente] protetta ricreerebbe all'infinito una nuova ChangeRequest pending invece di
    # applicare davvero la modifica decisa.
    #
    # Il gate RBAC `secrets.manage` è verificato dal chiamante (controller, C2b): qui il service assume
    # l'attore già autorizzato e applica SOLO i vincoli di chi può decidere — separazione 4-eyes (difesa
    # in profondità, DecisionGuard#requester?/#self_decision) e vincolo umano (CYRA-640,
    # DecisionGuard#human_actor?/#machine_decision).
    #
    # Il vincolo umano è il PRIMO controllo, prima di lock, stato e scritture: una macchina non deve
    # nemmeno arrivare a scoprire in che stato è la richiesta, e uscendo qui non produce decisione,
    # evento di audit (Set/Delete non vengono chiamati) né notifica.
    #
    # Audit: l'evento emesso da Set/Delete (action set/deleted) porta `actor: change_request.requested_by`
    # — l'autore REALE della modifica del secret è chi l'ha CHIESTA, non chi l'ha approvata. L'approvatore
    # resta comunque tracciato per sempre su `change_request.decided_by` (colonna della CR, mai perso).
    #
    # Lock + guard stale + applicazione sono nella STESSA transazione: se l'applicazione fallisce
    # (Result.err, es. capability secrets disabilitata sull'ambiente in creazione) l'errore propaga e la
    # CR NON viene marcata applied — resta pending, ridecidibile (pattern gemello di
    # Secrets::Variables::Import/Projects::Tokens::Rotate: cattura l'errore, ActiveRecord::Rollback,
    # ritorna Result.err fuori dal blocco).
    class Approve < ApplicationService
      include DecisionGuard

      def initialize(change_request:, actor:)
        @change_request = change_request
        @actor = actor
      end

      def call
        return machine_decision unless human_actor?

        failure = nil

        ApplicationRecord.transaction do
          @change_request.lock!
          return stale if stale?
          return self_decision if requester?
          return forbidden_environment unless environment_allowed?

          application = apply
          if application.err?
            failure = application.error
            raise ActiveRecord::Rollback
          end

          @change_request.update!(status: :applied, decided_by: @actor, decided_at: Time.current)
        end

        return Result.err(failure) if failure

        enqueue_change_request_notification(event: "approved")
        Result.ok(@change_request)
      end

      private

      # Notifica al richiedente (CYRA-138, Fase 4 pezzo C2c): SOLO dopo un'applicazione riuscita —
      # questa riga non è mai raggiunta sui rami stale/self_decision (return non-locale dentro la
      # transazione) né su un'applicazione fallita (return Result.err sopra). Mai after_commit, stesso
      # motivo di Submit (vedi Secrets::Notifications::ChangeRequestNotifyJob).
      def enqueue_change_request_notification(event:)
        ::Secrets::Notifications::ChangeRequestNotifyJob.perform_later(
          change_request_id: @change_request.id, event: event
        )
      end

      def apply
        @change_request.set? ? apply_set : apply_remove
      end

      def apply_set
        if @change_request.description_only_change?
          return ::Secrets::Variables::UpdateDescription.call(
            project: @change_request.project, environment: @change_request.environment,
            name: @change_request.name, description: @change_request.proposed_description,
            actor: @change_request.requested_by
          )
        end

        ::Secrets::Variables::Set.call(
          project: @change_request.project, environment: @change_request.environment,
          name: @change_request.name, value: @change_request.value,
          actor: @change_request.requested_by, description: @change_request.proposed_description
        )
      end

      # Una :remove su una variabile già assente è un no-op idempotente (come Submit#apply_remove):
      # lo stato finale desiderato — il secret non esiste — è già quello vero, nessun errore.
      def apply_remove
        variable = @change_request.project.secret_variables.find_by(
          environment: @change_request.environment, name: @change_request.name
        )
        return Result.ok(nil) if variable.nil?

        ::Secrets::Variables::Delete.call(variable:, actor: @change_request.requested_by)
      end
    end
  end
end
