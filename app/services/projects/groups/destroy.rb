# frozen_string_literal: true

module Projects
  module Groups
    # Cancella un gruppo nel medesimo ordine dei mutatori dispatch: project → group. I progetti già
    # collegati sono bloccati prima del gruppo; nuovi collegamenti devono prendere il group lock e quindi
    # si linearizzano interamente prima o dopo la cancellazione.
    #
    # MT-9: il primo anello della catena erano gli agenti che puntavano al gruppo via Connections::AgentTarget.
    # Rimossi i typed agent, nessuno punta più a un gruppo per lavorarlo — lo scope di un host è la ProjectScope
    # del suo service account, che non passa da qui.
    class Destroy < ApplicationService
      def initialize(group:)
        @group = group
      end

      def call
        ApplicationRecord.transaction do
          lock_grouped_projects
          @group.lock!
          @group.destroy!
        end
        Result.ok(true)
      end

      private

      def lock_grouped_projects
        project_ids = Projects::Project.where(group: @group).pluck(:id)
        Projects::Project.where(id: project_ids).order(:id).lock.load
      end
    end
  end
end
