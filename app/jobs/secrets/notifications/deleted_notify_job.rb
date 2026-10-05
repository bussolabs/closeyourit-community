# frozen_string_literal: true

module Secrets
  module Notifications
    # Notifica di cancellazione di un secret (CYRA-138, Fase 4 pezzo B): enqueued esplicitamente da
    # Secrets::Variables::Delete DOPO la distruzione (mai after_commit — Solid Queue vive su un DB
    # separato dal primary, un enqueue in transazione girerebbe prima del commit). Riceve SOLO dati
    # primitivi SNAPSHOTTATI prima/durante la distruzione — mai la variabile, già distrutta — e li
    # ricarica/passa al dispatch (Ticketing::NotifyJob è il gemello di questo pattern per i ticket).
    class DeletedNotifyJob < ApplicationJob
      queue_as :notifications

      def perform(project_id:, variable_id:, name:, environment_label:, actor_id: nil)
        project = ::Projects::Project.find_by(id: project_id)
        return if project.nil?

        actor = actor_id ? ::Accounts::Account.find_by(id: actor_id) : nil
        Secrets::Notifications::DispatchSecretDeleted.call(
          project: project, variable_id: variable_id, name: name,
          environment_label: environment_label, actor: actor
        )
      end
    end
  end
end
