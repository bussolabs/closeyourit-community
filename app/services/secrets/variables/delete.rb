# frozen_string_literal: true

module Secrets
  module Variables
    # Elimina una variabile del vault. Il controller la risolve nello scope del progetto (anti-BOLA);
    # qui solo la distruzione + gli hook post-cancellazione (audit, sync, notifica).
    class Delete < ApplicationService
      include Secrets::Github::Syncable

      def initialize(variable:, actor: nil)
        @variable = variable
        @actor = actor
      end

      def call
        project = @variable.project
        environment = @variable.environment
        name = @variable.name
        variable_id = @variable.id

        @variable.destroy!
        ::Secrets::RecordEvent.call(action: "deleted", project:, environment:, actor: @actor, name:)
        enqueue_github_sync(project)
        enqueue_deleted_notification(project:, variable_id:, name:, environment:)
        Result.ok(@variable)
      rescue ActiveRecord::RecordNotDestroyed => e
        Result.err(AppError.new(e.message, code: "R422-SECRET-002"))
      end

      private

      # Notifica ai responsabili del progetto (CYRA-138, Fase 4 pezzo B): SOLO dati primitivi
      # snapshottati, mai la variabile (già distrutta a questo punto). Async, dopo il commit implicito
      # della destroy — mai after_commit (Solid Queue vive su un DB separato).
      def enqueue_deleted_notification(project:, variable_id:, name:, environment:)
        ::Secrets::Notifications::DeletedNotifyJob.perform_later(
          project_id: project.id, variable_id: variable_id, name: name,
          environment_label: environment.label, actor_id: @actor&.id
        )
      end
    end
  end
end
